//

import AppKit
import SwiftUI

@main
struct MouthApp: App {
    @StateObject private var appController = MouthAppController()

    var body: some Scene {
        Settings {
            SettingsView(model: appController.sessionsModel, updater: appController.updater)
        }
        .defaultSize(width: 430, height: 240)
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}
