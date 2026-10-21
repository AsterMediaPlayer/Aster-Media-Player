//
//  AsterFINApp.swift
//  AsterFIN
//
//  Created by Phillip Berryman on 10/9/26.
//

import SwiftUI
import AVFoundation

@main
struct AsterFINApp: App {
    @State private var session = AppSession.shared

    init() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
        #if DEBUG && os(tvOS)
        Self.logFocusMoves()
        #endif
    }

    #if DEBUG && os(tvOS)
    /// Every focus move the system makes: what took focus (its kind and
    /// where it is on screen), and which way the press went, timed, to tell a
    /// stray stop from a card that's just slow to say it's focused.
    private static func logFocusMoves() {
        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            func describe(_ item: UIFocusItem?) -> String {
                guard let item else { return "nothing" }
                let frame = (item as? UIView).map { $0.convert($0.bounds, to: nil) } ?? item.frame
                return "\(type(of: item)) at x \(Int(frame.minX)) y \(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
            }
            let heading: String = switch context.focusHeading {
            case .down: "down"
            case .up: "up"
            case .left: "left"
            case .right: "right"
            default: "-"
            }
            let time = Date().formatted(.dateTime.minute().second().secondFraction(.fractional(3)))
            print("DEBUG focus: \(time) system \(heading): \(describe(context.previouslyFocusedItem)) -> \(describe(context.nextFocusedItem))")
        }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    session.router.handle(url)
                }
        }
        #if os(macOS)
        // View › Show/Hide Sidebar (⌃⌘S), from any page. A two-finger swipe
        // only reveals the sidebar at a tab's top page; elsewhere it goes back.
        .commands {
            SidebarCommands()
        }
        #endif
        #if os(iOS)
        // Downloads finish in the background; the system relaunches the app
        // to hand over their results.
        .backgroundTask(.urlSession(DownloadStore.wifiSessionID)) {
            await DownloadStore.shared.waitForBackgroundEvents()
        }
        .backgroundTask(.urlSession(DownloadStore.cellularSessionID)) {
            await DownloadStore.shared.waitForBackgroundEvents()
        }
        .backgroundTask(.urlSession(AudiobookDownloads.wifiSessionID)) {
            await AudiobookDownloads.shared.waitForBackgroundEvents()
        }
        .backgroundTask(.urlSession(AudiobookDownloads.cellularSessionID)) {
            await AudiobookDownloads.shared.waitForBackgroundEvents()
        }
        #endif
        #if os(macOS)
        // Aster › Settings… (⌘,).
        Settings {
            MacSettingsView()
                .environment(session)
                .preferredColorScheme(.dark)
        }
        #endif
    }
}
