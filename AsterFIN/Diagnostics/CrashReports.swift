//
//  CrashReports.swift
//  AsterFIN
//
//  The last crash, kept to offer in a debug report. The system collects
//  crash diagnostics itself and hands them to the app on a later launch
//  (MetricKit), on iPhone, iPad and Mac. The Apple TV has no such service,
//  so a crash there isn't captured; its report carries the run's log.
//

import Foundation
#if canImport(MetricKit) && !os(tvOS)
import MetricKit
#endif

nonisolated enum CrashReports {
    private static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "last-crash.json")
    }

    /// The crash the last run ended in, if there was one and it hasn't been sent or put aside.
    static var pending: String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    /// The crash has been sent, or the viewer chose not to: it isn't offered again.
    static func clear() { try? FileManager.default.removeItem(at: file) }

    /// Starts listening; once, as the app opens.
    static func start() {
        #if canImport(MetricKit) && !os(tvOS)
        MXMetricManager.shared.add(Listener.shared)
        // Any the system held while the app wasn't running.
        Listener.shared.keep(MXMetricManager.shared.pastDiagnosticPayloads)
        #endif
    }

    #if canImport(MetricKit) && !os(tvOS)
    private final class Listener: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
        static let shared = Listener()

        func didReceive(_ payloads: [MXDiagnosticPayload]) { keep(payloads) }

        func keep(_ payloads: [MXDiagnosticPayload]) {
            let crashes = payloads.flatMap { $0.crashDiagnostics ?? [] }
            guard !crashes.isEmpty else { return }
            let text = crashes.map { String(decoding: $0.jsonRepresentation(), as: UTF8.self) }.joined(separator: "\n")
            try? String(text.suffix(150_000)).write(to: CrashReports.file, atomically: true, encoding: .utf8)
        }
    }
    #endif
}
