import AppKit
import Combine
import Foundation

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let model: CodexSessionsViewModel
    private let stopHandler: () -> Void
    private let togglePauseHandler: () -> Void
    private let openSettingsHandler: () -> Void
    private let quitHandler: () -> Void

    private var speakingObserver: NSObjectProtocol?
    private var currentItemObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var menu: NSMenu?
    private weak var pauseItem: NSMenuItem?
    private weak var openThreadItem: NSMenuItem?
    private var currentSpeakingSessionID: String?
    private var isPaused = false
    private var isSpeaking = false
    private var iconOverrideSymbolName: String?

    private var menuFlagsMonitor: Any?

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
            // NSStatusBarButton may swallow command-click (Cmd-drag is used to rearrange items).
            // Gesture recognizers are more reliable for modified clicks (Cmd, Ctrl, etc).
            button.target = nil
            button.action = nil

            let leftClick = NSClickGestureRecognizer(target: self, action: #selector(didLeftClick(_:)))
            leftClick.buttonMask = 0x1
            button.addGestureRecognizer(leftClick)

            let rightClick = NSClickGestureRecognizer(target: self, action: #selector(didRightClick(_:)))
            rightClick.buttonMask = 0x2
            button.addGestureRecognizer(rightClick)

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
                self.updateOpenThreadMenuItem()
                self.updateIcon()
            }
            .store(in: &cancellables)

        speakingObserver = NotificationCenter.default.addObserver(
            forName: .codexVoiceAnnouncerSpeakingChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let speaking = (note.userInfo?["speaking"] as? Bool) ?? false
            self.isSpeaking = speaking
            if !speaking {
                self.currentSpeakingSessionID = nil
                self.iconOverrideSymbolName = nil
            }
            self.updateOpenThreadMenuItem()
            self.updateIcon()
        }

        currentItemObserver = NotificationCenter.default.addObserver(
            forName: .codexVoiceAnnouncerCurrentItemChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.currentSpeakingSessionID = note.userInfo?["sessionID"] as? String
            self.updateOpenThreadMenuItem()
        }
    }

    deinit {
        if let speakingObserver {
            NotificationCenter.default.removeObserver(speakingObserver)
        }
        if let currentItemObserver {
            NotificationCenter.default.removeObserver(currentItemObserver)
        }
        if let menuFlagsMonitor {
            NSEvent.removeMonitor(menuFlagsMonitor)
        }
    }

    @objc private func didLeftClick(_ recognizer: NSGestureRecognizer) {
        guard recognizer.state == .ended else { return }

        let flags = NSApp.currentEvent?.modifierFlags ?? []

        // Treat control-click as right-click (common macOS convention).
        if flags.contains(.control) {
            if let menu {
                statusItem.popUpMenu(menu)
            }
            return
        }

        handleLeftClick(commandHeld: flags.contains(.command))
    }

    @objc private func didRightClick(_ recognizer: NSGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        if let menu {
            statusItem.popUpMenu(menu)
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let openThread = NSMenuItem(title: "Open Thread in Codex", action: #selector(didOpenThread), keyEquivalent: "")
        openThread.target = self
        menu.addItem(openThread)
        openThreadItem = openThread

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
        updateOpenThreadMenuItem()
    }

    private func handleLeftClick(commandHeld: Bool) {
        if isSpeaking {
            if commandHeld, openCurrentThreadInCodex() {
                return
            }

            // Click while speaking: stop playback + clear queue.
            // Also update local state immediately so the next click toggles pause.
            stopHandler()
            isSpeaking = false
            currentSpeakingSessionID = nil
            iconOverrideSymbolName = nil
            updateOpenThreadMenuItem()
            updateIcon()
        } else {
            togglePauseHandler()
        }
    }

    @objc private func didTogglePause() {
        togglePauseHandler()
    }

    @objc private func didOpenThread() {
        _ = openCurrentThreadInCodex()
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

    private func updateOpenThreadMenuItem() {
        guard let item = openThreadItem else { return }

        if isSpeaking, let id = currentSpeakingSessionID, canOpenCodexThread(sessionID: id) {
            item.isEnabled = true
        } else {
            item.isEnabled = false
        }
    }

    private func canOpenCodexThread(sessionID: String) -> Bool {
        guard let url = URL(string: "codex://threads/\(sessionID)") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    @discardableResult
    private func openCurrentThreadInCodex() -> Bool {
        guard isSpeaking, let id = currentSpeakingSessionID else { return false }
        guard let url = URL(string: "codex://threads/\(id)") else { return false }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private func updateIcon(isSpeaking: Bool) {
        self.isSpeaking = isSpeaking
        updateIcon()
    }

    private func updateIcon() {
        let img: NSImage?

        if isSpeaking, let override = iconOverrideSymbolName {
            img = NSImage(systemSymbolName: override, accessibilityDescription: nil)
        } else if isPaused {
            // When disabled altogether: show mouth (not filled).
            img = NSImage(systemSymbolName: "mouth", accessibilityDescription: nil)
        } else if isSpeaking {
            // When speaking: show stop icon.
            img = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        } else {
            // Enabled but idle: keep your original mouth.fill.
            img = NSImage(systemSymbolName: "mouth.fill", accessibilityDescription: nil)
        }

        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = isPaused ? "Mouth (Paused)" : (isSpeaking ? "Mouth (Speaking)" : "Mouth")
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if menuFlagsMonitor == nil {
            menuFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                guard let self else { return event }
                self.updateHoverIcon()
                return event
            }
        }
        updateHoverIcon()
    }

    func menuDidClose(_ menu: NSMenu) {
        if let menuFlagsMonitor {
            NSEvent.removeMonitor(menuFlagsMonitor)
            self.menuFlagsMonitor = nil
        }
        iconOverrideSymbolName = nil
        updateIcon()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        updateHoverIcon()
    }

    private func updateHoverIcon() {
        guard isSpeaking else {
            if iconOverrideSymbolName != nil {
                iconOverrideSymbolName = nil
                updateIcon()
            }
            return
        }

        let highlighted = menu?.highlightedItem
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        let shouldOverride = (highlighted === openThreadItem) && commandHeld

        let newOverride = shouldOverride ? "magnifyingglass" : nil
        if iconOverrideSymbolName != newOverride {
            iconOverrideSymbolName = newOverride
            updateIcon()
        }
    }
}
