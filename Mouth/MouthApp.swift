//

import SwiftUI

@main
struct MouthApp: App {
    @StateObject private var sessionsModel: CodexSessionsViewModel
    private let statusItemController: StatusItemController

    init() {
        let engine = MouthEngine()
        let model = CodexSessionsViewModel(engine: engine)
        _sessionsModel = StateObject(wrappedValue: model)

        statusItemController = StatusItemController(model: model, stopHandler: {
            model.stopSpeakingAndClearQueue()
        }, togglePauseHandler: {
            model.togglePaused()
        }, openSettingsHandler: {
            NSApp.activate(ignoringOtherApps: true)
            let sel = Selector(("showSettingsWindow:"))
            if !NSApp.sendAction(sel, to: nil, from: nil) {
                _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }, quitHandler: {
            NSApp.terminate(nil)
        })
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: sessionsModel)
        }
        Settings {
            SettingsView(model: sessionsModel)
        }
    }
}
