import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private let model: CodexSessionsViewModel
    private let updater: UpdaterProviding

    init(model: CodexSessionsViewModel, updater: UpdaterProviding) {
        self.model = model
        self.updater = updater

        let view = SettingsView(model: model, updater: updater)
        let hosting = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = hosting

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        // Make sure the window actually appears and the app comes to front.
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
