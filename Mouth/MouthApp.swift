//

import AppKit
import SwiftUI

@main
struct MouthApp: App {
    @StateObject private var sessionsModel: CodexSessionsViewModel
    private let updater: UpdaterProviding
    private let statusItemController: StatusItemController
    private let settingsWindowController: SettingsWindowController

    init() {
        LaunchAtLoginManager.applySavedSetting()

        let updater = makeUpdaterController()
        self.updater = updater

        let engine = MouthEngine()
        let model = CodexSessionsViewModel(engine: engine)
        _sessionsModel = StateObject(wrappedValue: model)

        let settingsWC = SettingsWindowController(model: model, updater: updater)
        self.settingsWindowController = settingsWC

        self.statusItemController = StatusItemController(model: model, stopHandler: {
            model.stopSpeakingAndClearQueue()
        }, togglePauseHandler: {
            model.togglePaused()
        }, checkForUpdatesHandler: {
            Task { @MainActor in
                if updater.isAvailable {
                    updater.checkForUpdates(nil)
                } else {
                    let alert = NSAlert()
                    alert.alertStyle = .informational
                    alert.messageText = "Updates Unavailable"
                    alert.informativeText = updater.unavailableReason ?? "Updates are unavailable in this build."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }, openSettingsHandler: {
            settingsWC.show()
        }, quitHandler: {
            NSApp.terminate(nil)
        })
    }

    var body: some Scene {
        Settings {
            SettingsView(model: sessionsModel, updater: updater)
        }
    }
}
