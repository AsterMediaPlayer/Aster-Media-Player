//
//  DownloadsActivity.swift
//  AsterFIN
//
//  Downloads under way on the Lock Screen and in the Dynamic Island: started
//  with the first, updated as they go (at most every few seconds, as the
//  system budgets updates), ended when the last finishes. iOS suspends the
//  app while downloads run in the background, so the bar holds still then
//  and catches up when the app is woken as downloads finish.
//

#if os(iOS)
import ActivityKit
import Foundation

enum DownloadsActivity {
    /// A download under way: its title, and how far it's got, 0 to 1.
    struct Running {
        var title: String
        var progress: Double
    }

    private static var activity: Activity<DownloadsActivityAttributes>?
    private static var lastUpdate = Date.distantPast
    private static var lastRemaining = 0
    /// What each store has running; the activity shows them together.
    private static var videos: [Running] = []
    private static var audiobooks: [Running] = []

    /// Movies and episodes, from `DownloadStore`.
    static func sync(_ records: [DownloadRecord]) {
        videos = records.filter { $0.state == .downloading }.map { Running(title: $0.item.displayTitle, progress: $0.progress) }
        refresh()
    }

    /// Audiobooks, from `AudiobookDownloads`.
    static func syncAudiobooks(_ running: [Running]) {
        audiobooks = running
        refresh()
    }

    private static func refresh() {
        let running = videos + audiobooks
        guard !running.isEmpty else {
            end()
            return
        }
        let state = DownloadsActivityAttributes.ContentState(
            title: running.first?.title ?? "",
            remaining: running.count,
            progress: running.map(\.progress).reduce(0, +) / Double(running.count)
        )
        if let activity {
            // A download starting or finishing shows at once; progress at
            // most every few seconds.
            guard running.count != lastRemaining || Date().timeIntervalSince(lastUpdate) > 3 else { return }
            lastUpdate = Date()
            lastRemaining = running.count
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            #if DEBUG
            print("DEBUG activity: Live Activities are off for Aster, so downloads don't show")
            #endif
            return
        }
        do {
            activity = try Activity.request(attributes: DownloadsActivityAttributes(), content: ActivityContent(state: state, staleDate: nil))
            lastUpdate = Date()
            lastRemaining = running.count
            #if DEBUG
            print("DEBUG activity: downloads activity started (\(running.count) running)")
            #endif
        } catch {
            #if DEBUG
            print("DEBUG activity: downloads activity didn't start: \(error)")
            #endif
        }
    }

    private static func end() {
        guard let activity else { return }
        self.activity = nil
        lastRemaining = 0
        let done = DownloadsActivityAttributes.ContentState(title: "Downloads finished", remaining: 0, progress: 1)
        Task { await activity.end(ActivityContent(state: done, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(60))) }
    }
}
#endif
