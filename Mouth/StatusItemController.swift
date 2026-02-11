import AppKit
import Combine
import Foundation

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let model: CodexSessionsViewModel
    private let stopHandler: () -> Void
    private let togglePauseHandler: () -> Void
    private let checkForUpdatesHandler: () -> Void
    private let updatesAvailability: @MainActor () -> Bool
    private let openSettingsHandler: () -> Void
    private let quitHandler: () -> Void

    private var speakingObserver: NSObjectProtocol?
    private var currentItemObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var menu: NSMenu?
    private weak var pauseItem: NSMenuItem?
    private weak var checkForUpdatesItem: NSMenuItem?
    private var currentSpeakingSessionID: String?
    private var isPaused = false
    private var isSpeaking = false

    private var playPauseInterceptor: PlayPauseMediaKeyInterceptor?

    init(
        model: CodexSessionsViewModel,
        stopHandler: @escaping () -> Void,
        togglePauseHandler: @escaping () -> Void,
        checkForUpdatesHandler: @escaping () -> Void,
        updatesAvailability: @MainActor @escaping () -> Bool,
        openSettingsHandler: @escaping () -> Void,
        quitHandler: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.model = model
        self.stopHandler = stopHandler
        self.togglePauseHandler = togglePauseHandler
        self.checkForUpdatesHandler = checkForUpdatesHandler
        self.updatesAvailability = updatesAvailability
        self.openSettingsHandler = openSettingsHandler
        self.quitHandler = quitHandler
        super.init()

        self.playPauseInterceptor = PlayPauseMediaKeyInterceptor(onPlayPauseKeyDown: { [weak self] in
            DispatchQueue.main.async {
                self?.stopSpeakingNow()
            }
        })

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
            guard let self else { return }
            let speaking = (note.userInfo?["speaking"] as? Bool) ?? false
            self.isSpeaking = speaking
            self.playPauseInterceptor?.setEnabled(speaking)
            if !speaking {
                self.currentSpeakingSessionID = nil
            }
            self.updateIcon()
        }

        currentItemObserver = NotificationCenter.default.addObserver(
            forName: .codexVoiceAnnouncerCurrentItemChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.currentSpeakingSessionID = note.userInfo?["sessionID"] as? String
        }
    }

    deinit {
        if let speakingObserver {
            NotificationCenter.default.removeObserver(speakingObserver)
        }
        if let currentItemObserver {
            NotificationCenter.default.removeObserver(currentItemObserver)
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
                // `popUpMenu` is deprecated; temporarily attach menu to the status item and show it.
                statusItem.menu = menu
                statusItem.button?.performClick(nil)
                statusItem.menu = nil
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

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(didCheckForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = false
        menu.addItem(updates)
        checkForUpdatesItem = updates

        Task { @MainActor [weak updates] in
            updates?.isEnabled = updatesAvailability()
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(didQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.menu = menu
        updatePauseMenuItem()
    }

    private func handleLeftClick() {
        if isSpeaking {
            // Click while speaking: stop playback + clear queue.
            // Also update local state immediately so the next click toggles pause.
            stopSpeakingNow()
        } else {
            togglePauseHandler()
        }
    }

    private func stopSpeakingNow() {
        stopHandler()
        isSpeaking = false
        currentSpeakingSessionID = nil
        updateIcon()
    }

    @objc private func didTogglePause() {
        togglePauseHandler()
    }

    @objc private func didOpenSettings() {
        openSettingsHandler()
    }

    @objc private func didCheckForUpdates() {
        checkForUpdatesHandler()
    }

    @objc private func didQuit() {
        quitHandler()
    }

    private func updatePauseMenuItem() {
        pauseItem?.title = isPaused ? "Resume" : "Pause"
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

        if isPaused {
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
}
