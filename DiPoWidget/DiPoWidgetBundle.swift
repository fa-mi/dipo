//
//  DiPoWidgetBundle.swift
//  DiPoWidget
//
//  Entry point for the widget extension. WidgetKit auto-discovers `@main`
//  `WidgetBundle` types and registers each `Widget` they declare in `body`.
//

import WidgetKit
import SwiftUI

@main
struct DiPoWidgetBundle: WidgetBundle {
    var body: some Widget {
        DiPoWidget()
    }
}
