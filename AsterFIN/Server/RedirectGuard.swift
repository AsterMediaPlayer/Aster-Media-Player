//
//  RedirectGuard.swift
//  AsterFIN
//
//  Keeps a server's sign-in from following a redirect to somewhere else.
//  URLSession drops Authorization when a redirect changes host, but carries
//  every other header over, Jellyfin's X-Emby-Authorization and Plex's
//  X-Plex-Token included, so a server, proxy or anyone able to answer a
//  plain-http request could pass the token on to a site of their choosing.
//

import Foundation

nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectGuard()

    /// Every header the app puts a token or sign-in in.
    static let credentialHeaders = ["Authorization", "X-Emby-Authorization", "X-Emby-Token", "X-MediaBrowser-Token", "X-Plex-Token"]

    // The completion-handler form: Swift 6.4's compiler crashes bridging the async one.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.guarded(request, from: task.originalRequest?.url))
    }

    /// `request` as sent on: unchanged within the address the request was
    /// first made to (scheme, host and port), else without its sign-in.
    static func guarded(_ request: URLRequest, from original: URL?) -> URLRequest {
        guard let original, let target = request.url, !sameOrigin(original, target) else { return request }
        var request = request
        for header in credentialHeaders { request.setValue(nil, forHTTPHeaderField: header) }
        return request
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased() && port(a) == port(b)
    }
}
