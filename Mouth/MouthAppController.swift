import AppKit
import Combine
import Foundation

@MainActor
final class MouthAppController: ObservableObject {
    let sessionsModel: CodexSessionsViewModel
    let updater: UpdaterProviding

    private let statusItemController: StatusItemController
    private let hotkeyController: HotkeyController

    init() {
        LaunchAtLoginManager.applySavedSetting()

        let updater = makeUpdaterController()
        self.updater = updater

        let engine = MouthEngine()
        let model = CodexSessionsViewModel(engine: engine)
        self.sessionsModel = model
        self.hotkeyController = HotkeyController()
        hotkeyController.bind(model: model)

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
                Self.openNativeSettings()
            },
            quitHandler: {
                NSApp.terminate(nil)
            }
        )
    }

    private static func openNativeSettings(retriesRemaining: Int = 2) {
        if let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu {
            let settingsItem = appMenu.items.first { item in
                if item.keyEquivalent == "," && item.keyEquivalentModifierMask.contains(.command) {
                    return true
                }
                let lowered = item.title.lowercased()
                return lowered.contains("settings") || lowered.contains("preferences")
            }
            if let settingsItem, let action = settingsItem.action {
                if #available(macOS 14.0, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
                _ = NSApp.sendAction(action, to: settingsItem.target, from: nil)
                return
            }
        }
        guard retriesRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.openNativeSettings(retriesRemaining: retriesRemaining - 1)
        }
    }
}
