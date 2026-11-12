//
//  VelaApp.swift
//  Vela
//
//  App entry. Starts directly in voice mode (after the short splash).
//

import SwiftUI

@main
struct VelaApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
