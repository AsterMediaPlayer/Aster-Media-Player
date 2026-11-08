//
//  ResponseCache.swift
//  AsterFIN
//
//  What a page last showed, kept on disk so it can show again at once on
//  the next launch or visit while the server's fresh answer is fetched.
//  Kept per server and user (never shown to anyone else), in Caches, so
//  the system may clear it; it's cleared on signing out too.
//

import CryptoKit
import Foundation

nonisolated enum ResponseCache {
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = base.appending(path: "Responses", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// The file for `name` on `server` for `user`: hashed, so neither shows.
    static func file(_ name: String, server: URL, user: String) -> URL {
        let key = "\(server.absoluteString)|\(user)|\(name)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: digest + ".json")
    }

    /// What was kept, and when, if anything.
    static func load<Value: Decodable>(_ type: Value.Type, _ name: String, server: URL, user: String) async -> (value: Value, saved: Date)? {
        let url = file(name, server: server, user: user)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let value = try? JSONDecoder().decode(Value.self, from: data) else { return nil }
            let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (value, saved)
        }.value
    }

    /// Keeps `value` for next time, written in the background.
    static func save<Value: Encodable & Sendable>(_ value: Value, _ name: String, server: URL, user: String) {
        let url = file(name, server: server, user: user)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Everything kept, for every server: on signing out or removing one.
    static func clear() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
