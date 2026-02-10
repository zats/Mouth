import AppKit
import Foundation

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let stopHandler: () -> Void
    private let togglePauseHandler: () -> Void
    private let quitHandler: () -> Void

    private var speakingObserver: NSObjectProtocol?
    private var menu: NSMenu?
    private weak var pauseItem: NSMenuItem?
    private var isPaused = false

    init(
        stopHandler: @escaping () -> Void,
        togglePauseHandler: @escaping () -> Void,
        quitHandler: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.stopHandler = stopHandler
        self.togglePauseHandler = togglePauseHandler
        self.quitHandler = quitHandler
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(didClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.toolTip = "Mouth"
        }

        updateIcon(isSpeaking: false)
        buildMenu()

        speakingObserver = NotificationCenter.default.addObserver(
            forName: .codexVoiceAnnouncerSpeakingChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let speaking = (note.userInfo?["speaking"] as? Bool) ?? false
            self?.updateIcon(isSpeaking: speaking)
        }
    }

    deinit {
        if let speakingObserver {
            NotificationCenter.default.removeObserver(speakingObserver)
        }
    }

    @objc private func didClick() {
        guard let event = NSApp.currentEvent else {
            stopHandler()
            return
        }

        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            if let menu {
                statusItem.popUpMenu(menu)
            }
        default:
            stopHandler()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let pause = NSMenuItem(title: "Pause", action: #selector(didTogglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause

        let settings = NSMenuItem(title: "Settings…", action: #selector(didOpenSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Exit", action: #selector(didQuit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        self.menu = menu
        updatePauseMenuItem()
    }

    @objc private func didTogglePause() {
        isPaused.toggle()
        updatePauseMenuItem()
        togglePauseHandler()
    }

    @objc private func didOpenSettings() {
        // no-op for now
    }

    @objc private func didQuit() {
        quitHandler()
    }

    private func updatePauseMenuItem() {
        pauseItem?.title = isPaused ? "Resume" : "Pause"
    }

    private func updateIcon(isSpeaking: Bool) {
        let symbolName = isSpeaking ? "stop.fill" : "mouth"
        let fallback = isSpeaking ? "stop.fill" : "waveform"
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = isSpeaking ? "Stop speaking" : "Mouth"
    }
}
