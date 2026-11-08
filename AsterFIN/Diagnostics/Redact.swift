//
//  Redact.swift
//  AsterFIN
//
//  What a debug report leaves out: anything that signs in (tokens, keys,
//  passwords), where the server is (addresses, host names, IPs), who's using
//  it (the user's name, email addresses), and the library's file paths, which
//  name the user's titles. The same rules as the Android app's, so a report
//  reads alike from every platform. Every line of a report passes through
//  `text` before it leaves the device.
//

import Foundation

nonisolated enum Redact {
    private static let rules: [(NSRegularExpression, String)] = {
        let table: [(String, String)] = [
            // Tokens and keys in addresses and headers: api_key=…, X-Emby-Token: …, X-Plex-Token=…, Token="…".
            (#"\b(api_?key|access_?token|x-emby-token|x-mediabrowser-token|x-plex-token|token|password|pw)(["']?\s*[:=]\s*["']?)[^\s"'&,;}]+"#, "$1$2<hidden>"),
            // A MediaBrowser authorization header's token, and its device id, which traces to the device.
            (#"\b(Token|DeviceId)="[^"]*""#, "$1=\"<hidden>\""),
            // A bearer or basic authorization.
            (#"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 <hidden>"),
            // An address: scheme and host (with any user and port), the path kept, since it says what was asked for.
            (#"\b(https?|wss?|rtsp)://[^\s/"'<>]+"#, "$1://<server>"),
            // Plex's own host names carry the server's IP and id.
            (#"\b[0-9a-z-]+\.(?:[0-9a-f]+\.)?plex\.direct\b"#, "<server>"),
            // IPv4 outside an address; a version number ("tvOS 27.0.1.2", "v1.2.3.4") isn't one.
            (#"(?<!\b(?:os|version|build|v)\s)(?<!\b(?:os|version|build|v))(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#, "<ip>"),
            (#"\b(?:[0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}\b"#, "<ip>"),
            // Email addresses.
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            // A media file's place in the library, which names the title: kept to its kind of file.
            (#"(?:[A-Z]:\\|/(?:mnt|media|data|srv|share|volume\d*|storage|home|Users|nas|library|movies|tv|Volumes)/)[^\n"'<>]*?\.(mkv|mp4|m4v|avi|ts|m2ts|iso|mov|webm|mp3|flac|m4a|m4b|aac|ogg|opus|srt|ass|ssa|vtt|sup)\b"#, "<path>.$1"),
        ]
        return table.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, template) }
        }
    }()

    /// A server's name that says nothing of whose it is (Emby and Jellyfin call themselves "Server"): left as it is.
    private static let generic: Set<String> = ["server", "emby", "jellyfin", "plex", "media", "home", "localhost"]

    /// `value` with everything above taken out; `names` (the user's name and account id, the server's own name) go too, as
    /// whole words and never inside a placeholder already put in. An id goes with and without its dashes.
    static func text(_ value: String, names: [String] = []) -> String {
        var out = value
        for (rule, template) in rules {
            out = rule.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        let words = Set(names.flatMap { [$0, $0.replacingOccurrences(of: "-", with: "")] })
            .filter { $0.count >= 3 && !generic.contains($0.lowercased()) }
            .sorted { $0.count > $1.count }
        for name in words {
            let pattern = "(?<![A-Za-z0-9<])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9>])"
            if let rule = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                out = rule.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<name>")
            }
        }
        return out
    }
}
