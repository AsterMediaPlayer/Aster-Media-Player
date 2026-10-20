//
//  NetworkPath.swift
//  AsterFIN
//
//  Whether the connection is cellular data, for the cellular streaming
//  limit on iPhone and iPad (`AppSettings.maxBitrate`).
//

import Foundation
import Network

nonisolated final class NetworkPath: @unchecked Sendable {
    static let shared = NetworkPath()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false

    /// On cellular data: the phone's own, or a Personal Hotspot (which iOS
    /// marks expensive too, as it's the phone's cellular data underneath).
    var isCellular: Bool { lock.withLock { expensive } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isExpensive = path.isExpensive
            lock.withLock { self.expensive = isExpensive }
        }
        monitor.start(queue: DispatchQueue(label: "AsterFIN.NetworkPath", qos: .utility))
    }

    /// Starts watching, so the first answer is ready before the first stream.
    func start() {}
}
