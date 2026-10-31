//
//  SonosRooms.swift
//  AsterFIN
//
//  Finds the Sonos rooms on the network. Speakers announce themselves over
//  Bonjour (`_sonos._tcp`); the first one that answers lists the whole
//  household's rooms and groups. Only looked for while the room picker is
//  open, so the Local Network question comes up when someone wants Sonos,
//  not when the app opens.
//

#if os(iOS)
import Foundation
import Network
import Synchronization

@MainActor
@Observable
final class SonosRooms {
    static let shared = SonosRooms()

    private(set) var groups: [SonosGroup] = []
    private(set) var isSearching = false
    /// The playing group's volume, 0 to 100, once read.
    private(set) var volume: Double?

    private var browser: NWBrowser?
    private var hosts: Set<String> = []
    private var volumeTask: Task<Void, Never>?

    func startSearching() {
        guard browser == nil else { return }
        isSearching = true
        let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor [weak self] in
                for endpoint in endpoints {
                    guard let host = await Self.address(of: endpoint) else { continue }
                    await self?.found(host)
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor [weak self] in self?.stopSearching() }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        // Rooms already known are checked again: groups change.
        Task { [weak self, hosts] in
            for host in hosts { await self?.found(host, force: true) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.isSearching = false
        }
    }

    func stopSearching() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    /// A speaker answered at `host`: the household's groups, as it sees them.
    private func found(_ host: String, force: Bool = false) async {
        guard force || !hosts.contains(host) else { return }
        hosts.insert(host)
        let speaker = SonosSpeaker(id: "", name: "", host: host)
        guard let found = try? await SonosClient(speaker: speaker).zoneGroups(), !found.isEmpty else { return }
        // This household's groups replace what was known of its rooms;
        // another household's (a second Sonos system) stay in the list.
        let rooms = Set(found.flatMap { $0.members.map(\.id) })
        let others = groups.filter { group in !group.members.contains { rooms.contains($0.id) } }
        groups = (others + found).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isSearching = false
    }

    /// The service's IPv4 address, from a moment's connection to it.
    nonisolated private static func address(of endpoint: NWEndpoint) async -> String? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let done = Mutex(false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ host: String?) {
                let first = done.withLock { finished in
                    defer { finished = true }
                    return !finished
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: host)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint, case .ipv4(let address) = host {
                        finish("\(address)".split(separator: "%").first.map(String.init))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }

    // MARK: Volume

    func readVolume(of group: SonosGroup) {
        Task {
            if let level = try? await SonosClient(speaker: group.coordinator).groupVolume() {
                volume = Double(level)
            }
        }
    }

    /// Sets the group's volume, the slider's last place winning.
    func setVolume(_ level: Double, of group: SonosGroup) {
        volume = level
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            try? await SonosClient(speaker: group.coordinator).setGroupVolume(Int(level.rounded()))
        }
    }
}
#endif
