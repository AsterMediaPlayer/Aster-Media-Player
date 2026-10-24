//
//  AsterFINWidgetsBundle.swift
//  AsterFINWidgets
//
//  The Home Screen widgets.
//

import SwiftUI
import WidgetKit

@main
struct AsterFINWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        OnNowWidget()
    }
}
