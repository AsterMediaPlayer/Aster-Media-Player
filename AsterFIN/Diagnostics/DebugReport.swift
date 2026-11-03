//
//  DebugReport.swift
//  AsterFIN
//
//  A bug report, in the shape Aster's report service takes (POST
//  /api/bug-reports, answered 201 {"id": …}), the same as the Android app
//  sends: what happened in the viewer's words, the app and device, the
//  server's kind and version, what was last played, the app's settings, and
//  a log of this run's notable moments, the last crash, what the device can
//  decode and the app's recent system log. Everything but the viewer's own
//  words passes through `Redact`, so sign-ins, addresses, names, ids and
//  library file names stay behind.
//

import AVFoundation
import Foundation
import OSLog
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum DebugReportError: LocalizedError {
    case service(String)
    case status(Int)
    case noId

    var errorDescription: String? {
        switch self {
        case .service(let message): "The report service said: \(message)"
        case .status(let code): "The report service answered \(code)."
        case .noId: "The report service didn't give the report's id."
        }
    }
}

nonisolated enum DebugReport {
    static let endpoint = URL(string: "https://astermediaplayer.com/api/bug-reports")!
    private static let logLines = 1500
    /// The service takes up to 1 MB of logs; the newest are kept.
    private static let maxLogs = 1_000_000
    private static let maxDescription = 10_000

    /// What goes in it, said to the viewer before it's sent.
    static let contents = "It holds the app's version, this device's model and what it can play, your server's kind and version, what was last played, the app's settings, and the app's recent log. Server addresses, sign-ins, passwords, your name and your library's file names are taken out before it leaves this device."

    static var platform: String {
        #if os(tvOS)
        "tvos"
        #elseif os(macOS)
        "macos"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    /// The device's model identifier ("iPhone16,2", "Mac15,6").
    static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "\(simulated) (simulator)" }
        var size = 0
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        sysctlbyname(key, nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    // MARK: Building

    /// The report. `description` is the viewer's own account; `contactEmail` an address they chose to give.
    @MainActor
    static func build(session: AppSession, description: String, crash: String?, contactEmail: String?) async -> [String: Any] {
        let names = [session.userName, session.userId, session.serverName].compactMap { $0 }
        func clean(_ text: String) -> String { Redact.text(text, names: names) }
        let info = Bundle.main.infoDictionary ?? [:]
        let words = description.trimmingCharacters(in: .whitespacesAndNewlines)

        var report: [String: Any] = [
            "description": String((words.isEmpty ? (crash != nil ? "The app closed unexpectedly." : "Sent from Settings > About.") : words).prefix(maxDescription)),
            "app": [
                "version": info["CFBundleShortVersionString"] as? String ?? "",
                "build": info["CFBundleVersion"] as? String ?? "",
                "platform": platform,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "device": deviceModel,
            ],
        ]
        if session.client != nil {
            var server: [String: Any] = ["type": session.serverKind.rawValue]
            if let version = try? await session.jellyfin?.publicSystemInfo().version { server["version"] = version }
            report["server"] = server
        }
        let played = DebugLog.lastPlayback
        if !played.isEmpty { report["playback"] = played.mapValues(clean) }
        report["settings"] = settings().mapValues(clean)
        if let email = contactEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty { report["contactEmail"] = email }
        let log = clean(logs(crash: crash))
        report["logs"] = String(log.suffix(maxLogs))
        return report
    }

    /// The app's preferences by name, as text, less any that hold a place, a name or a sign-in.
    static func settings(from defaults: [String: Any] = UserDefaults.standard.dictionaryRepresentation()) -> [String: String] {
        let withheld = ["url", "address", "deviceid", "server", "user", "token", "secret", "password", "library", "libraries", "welcome", "seerr", "mdblist", "tracker"]
        var found: [String: String] = [:]
        for (key, value) in defaults where key.hasPrefix("AsterFIN.") {
            let name = String(key.dropFirst("AsterFIN.".count))
            if withheld.contains(where: { name.lowercased().contains($0) }) { continue }
            switch value {
            case let value as Bool: found[name] = value ? "true" : "false"
            case let value as NSNumber: found[name] = value.stringValue
            case let value as String where value.count <= 80: found[name] = value
            default: break
            }
        }
        return found
    }

    private static func logs(crash: String?) -> String {
        var out = "== Device\n"
        #if os(tvOS)
        out += "TV: true\n"
        #endif
        out += "Hardware decoding: " + [("H.264", kCMVideoCodecType_H264), ("HEVC", kCMVideoCodecType_HEVC), ("AV1", kCMVideoCodecType_AV1)]
            .map { "\($0.0) \(VTIsHardwareDecodeSupported($0.1) ? "yes" : "no")" }.joined(separator: ", ") + "\n"
        out += "HDR playback: \(AVPlayer.eligibleForHDRPlayback ? "yes" : "no")\n"
        #if !os(macOS)
        out += "Audio output: " + AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", ") + "\n"
        #endif
        out += "Low power mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")\n"
        if let crash {
            out += "\n== Crash (last run)\n\(crash)\n"
        }
        out += "\n== This run\n" + DebugLog.recent().joined(separator: "\n") + "\n"
        out += "\n== System log (this app)\n" + appLog().joined(separator: "\n") + "\n"
        return out
    }

    /// This app's own recent lines in the system log, which an app may read for itself.
    private static func appLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(timeIntervalSinceLatestBoot: 0)) else { return [] }
        let lines = entries.compactMap { $0 as? OSLogEntryLog }
            .filter { $0.level != .debug }
            .map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.category)] \($0.composedMessage)" }
        return Array(lines.suffix(logLines))
    }

    // MARK: Sending

    /// Sends `report`; the id the service gave it.
    static func send(_ report: [String: Any]) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aster for \(platform)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: report)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            if let message = answer?["error"] as? String, !message.isEmpty { throw DebugReportError.service(message) }
            throw DebugReportError.status(status)
        }
        guard let id = answer?["id"] as? String, !id.isEmpty else { throw DebugReportError.noId }
        return id
    }
}
