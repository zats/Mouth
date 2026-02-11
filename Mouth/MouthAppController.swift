import AppKit
import Combine
import Foundation

@MainActor
final class MouthAppController: ObservableObject {
    let sessionsModel: CodexSessionsViewModel
    let updater: UpdaterProviding

    private let statusItemController: StatusItemController
    private let settingsWindowController: SettingsWindowController

    init() {
        LaunchAtLoginManager.applySavedSetting()

        let updater = makeUpdaterController()
        self.updater = updater

        let engine = MouthEngine()
        let model = CodexSessionsViewModel(engine: engine)
        self.sessionsModel = model

        let settingsWC = SettingsWindowController(model: model, updater: updater)
        self.settingsWindowController = settingsWC

        self.statusItemController = StatusItemController(
            model: model,
            stopHandler: {
                model.stopSpeakingAndClearQueue()
            },
            togglePauseHandler: {
                model.togglePaused()
            },
            checkForUpdatesHandler: {
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
            },
            updatesAvailability: {
                updater.isAvailable
            },
            openSettingsHandler: {
                settingsWC.show()
            },
            quitHandler: {
                NSApp.terminate(nil)
            }
        )
    }
}
