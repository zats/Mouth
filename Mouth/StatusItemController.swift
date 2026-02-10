import AppKit
import Combine
import Foundation

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let model: CodexSessionsViewModel
    private let stopHandler: () -> Void
    private let togglePauseHandler: () -> Void
    private let openSettingsHandler: () -> Void
    private let quitHandler: () -> Void

    private var speakingObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var menu: NSMenu?
    private weak var pauseItem: NSMenuItem?
    private var isPaused = false
    private var isSpeaking = false

    init(
        model: CodexSessionsViewModel,
        stopHandler: @escaping () -> Void,
        togglePauseHandler: @escaping () -> Void,
        openSettingsHandler: @escaping () -> Void,
        quitHandler: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.model = model
        self.stopHandler = stopHandler
        self.togglePauseHandler = togglePauseHandler
        self.openSettingsHandler = openSettingsHandler
        self.quitHandler = quitHandler
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(didClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.toolTip = "Mouth"
        }

        isPaused = model.isPaused
        updateIcon(isSpeaking: false)
        buildMenu()

        model.$isPaused
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                guard let self else { return }
                self.isPaused = paused
                self.updatePauseMenuItem()
                self.updateIcon()
            }
            .store(in: &cancellables)

        speakingObserver = NotificationCenter.default.addObserver(
            forName: .codexVoiceAnnouncerSpeakingChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let speaking = (note.userInfo?["speaking"] as? Bool) ?? false
            self?.isSpeaking = speaking
            self?.updateIcon()
        }
    }

    deinit {
        if let speakingObserver {
            NotificationCenter.default.removeObserver(speakingObserver)
        }
    }

    @objc private func didClick() {
        guard let event = NSApp.currentEvent else {
            handleLeftClick()
            return
        }

        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            if let menu {
                statusItem.popUpMenu(menu)
            }
        default:
            handleLeftClick()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let pause = NSMenuItem(title: "Pause", action: #selector(didTogglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause

        let settings = NSMenuItem(title: "Settings…", action: #selector(didOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(didQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.menu = menu
        updatePauseMenuItem()
    }

    private func handleLeftClick() {
        if isSpeaking {
            // First click while speaking: stop playback + clear queue.
            // Also update local state immediately so the next click toggles pause.
            stopHandler()
            isSpeaking = false
            updateIcon()
        } else {
            togglePauseHandler()
        }
    }

    @objc private func didTogglePause() {
        togglePauseHandler()
    }

    @objc private func didOpenSettings() {
        openSettingsHandler()
    }

    @objc private func didQuit() {
        quitHandler()
    }

    private func updatePauseMenuItem() {
        pauseItem?.title = isPaused ? "Resume" : "Pause"
    }

    private func updateIcon(isSpeaking: Bool) {
        self.isSpeaking = isSpeaking
        updateIcon()
    }

    private func updateIcon() {
        let img: NSImage?

        if isPaused {
            // When disabled altogether: show mouth (not filled).
            img = NSImage(systemSymbolName: "mouth", accessibilityDescription: nil)
        } else if isSpeaking {
            // When speaking: show custom pause badge icon.
            img = NSImage(named: "custom.mouth.fill.badge.pause")
                ?? NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        } else {
            // Enabled but idle: keep your original mouth.fill.
            img = NSImage(systemSymbolName: "mouth.fill", accessibilityDescription: nil)
        }

        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = isPaused ? "Mouth (Paused)" : (isSpeaking ? "Mouth (Speaking)" : "Mouth")
    }
}
