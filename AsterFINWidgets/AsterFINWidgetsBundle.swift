//
//  AsterFINWidgetsBundle.swift
//  AsterFINWidgets
//
//  The Home Screen widgets and the Live Activities.
//

import SwiftUI
import WidgetKit

@main
struct AsterFINWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        OnNowWidget()
        DownloadsLiveActivity()
        ChannelLiveActivity()
    }
}
