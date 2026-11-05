//
//  DebugLog.swift
//  AsterFIN
//
//  What a debug report tells of this run: notable moments (each playback
//  attempt, how it played, why it failed, how a sign-in went), kept in
//  memory, and also sent to the system log, which a report reads too.
//

import Foundation
import os

nonisolated enum DebugLog {
    private static let keep = 300
    private static let logger = Logger(subsystem: "app.asterfin.report", category: "run")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var events: [String] = []
    nonisolated(unsafe) private static var playback: [String: String] = [:]

    private static let stamp: Date.FormatStyle = Date.FormatStyle(date: .numeric, time: .standard)

    /// A moment worth a report's notice.
    static func note(_ tag: String, _ message: String) {
        logger.info("[\(tag, privacy: .public)] \(message, privacy: .private)")
        let line = "\(Date().formatted(stamp)) [\(tag)] \(message)"
        lock.withLock {
            events.append(line)
            if events.count > keep { events.removeFirst(events.count - keep) }
        }
    }

    static func recent() -> [String] { lock.withLock { events } }

    /// What was last played, field by field (container, codecs, how it played, any error), for a report's `playback`.
    static var lastPlayback: [String: String] {
        get { lock.withLock { playback } }
        set { lock.withLock { playback = newValue } }
    }

    /// Adds to what was last played.
    static func notePlayback(_ fields: [String: String]) {
        lock.withLock { playback.merge(fields) { _, new in new } }
    }

    static func startedPlayback() { lock.withLock { playback = [:] } }
}
