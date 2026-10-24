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
    private static var activity: Activity<DownloadsActivityAttributes>?
    private static var lastUpdate = Date.distantPast
    private static var lastRemaining = 0

    static func sync(_ records: [DownloadRecord]) {
        let running = records.filter { $0.state == .downloading }
        guard !running.isEmpty else {
            end()
            return
        }
        let state = DownloadsActivityAttributes.ContentState(
            title: running.first?.item.displayTitle ?? "",
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
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(attributes: DownloadsActivityAttributes(), content: ActivityContent(state: state, staleDate: nil))
            lastUpdate = Date()
            lastRemaining = running.count
        }
    }

    private static func end() {
        guard let activity else { return }
        self.activity = nil
        let done = DownloadsActivityAttributes.ContentState(title: "Downloads finished", remaining: 0, progress: 1)
        Task { await activity.end(ActivityContent(state: done, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(60))) }
    }
}
#endif
