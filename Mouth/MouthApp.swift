//

import SwiftUI

@main
struct MouthApp: App {
    @StateObject private var sessionsModel: CodexSessionsViewModel
    private let statusItemController: StatusItemController
    private let settingsWindowController: SettingsWindowController

    init() {
        LaunchAtLoginManager.applySavedSetting()

        let engine = MouthEngine()
        let model = CodexSessionsViewModel(engine: engine)
        _sessionsModel = StateObject(wrappedValue: model)

        let settingsWC = SettingsWindowController(model: model)
        settingsWindowController = settingsWC

        statusItemController = StatusItemController(model: model, stopHandler: {
            model.stopSpeakingAndClearQueue()
        }, togglePauseHandler: {
            model.togglePaused()
        }, openSettingsHandler: {
            settingsWC.show()
        }, quitHandler: {
            NSApp.terminate(nil)
        })
    }

    var body: some Scene {
        Settings {
            SettingsView(model: sessionsModel)
        }
    }
}
