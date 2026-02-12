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
    private var defaultsObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var menu: NSMenu?
    private weak var stopSpeechItem: NSMenuItem?
    private weak var pauseItem: NSMenuItem?
    private weak var checkForUpdatesItem: NSMenuItem?
    private var currentSpeakingSessionID: String?
    private var isPaused = false
    private var isSpeaking = false
    private var waveformTimer: Timer?
    private let waveformSymbols = ["waveform.low", "waveform.mid", "waveform"]
    private var currentWaveformSymbol: String?

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
            button.imageScaling = .scaleProportionallyDown
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
            self.updatePlayPauseInterception()
            if !speaking {
                self.currentSpeakingSessionID = nil
            }
            self.updateStopSpeechMenuItem()
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

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePlayPauseInterception()
        }
    }

    deinit {
        waveformTimer?.invalidate()
        waveformTimer = nil

        if let speakingObserver {
            NotificationCenter.default.removeObserver(speakingObserver)
        }
        if let currentItemObserver {
            NotificationCenter.default.removeObserver(currentItemObserver)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
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
        updateStopSpeechMenuItem()
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
        updateStopSpeechMenuItem()
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

    @objc private func didStopSpeech() {
        stopSpeakingNow()
    }

    @objc private func didQuit() {
        quitHandler()
    }

    private func updatePauseMenuItem() {
        pauseItem?.title = isPaused ? "Resume" : "Pause"
    }

    private func shouldUsePlayPauseMediaKeyForStop() -> Bool {
        StopSpeechHotkeyMode.current == .mediaPlayPause
    }

    private func updatePlayPauseInterception() {
        playPauseInterceptor?.setEnabled(isSpeaking && shouldUsePlayPauseMediaKeyForStop())
    }

    private func updateStopSpeechMenuItem() {
        guard let menu else { return }

        if isSpeaking {
            if stopSpeechItem == nil {
                let stopSpeech = NSMenuItem(title: "Stop Speech", action: #selector(didStopSpeech), keyEquivalent: "")
                stopSpeech.target = self
                menu.insertItem(stopSpeech, at: 0)
                stopSpeechItem = stopSpeech
            }
        } else if let stopSpeechItem {
            menu.removeItem(stopSpeechItem)
            self.stopSpeechItem = nil
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
        if isPaused {
            stopWaveformAnimation()
            setStatusItemSymbol("mouth.disabled.custom")
        } else if isSpeaking {
            startWaveformAnimationIfNeeded()
        } else {
            stopWaveformAnimation()
            setStatusItemSymbol("mouth.fill")
        }

        statusItem.button?.toolTip = isPaused ? "Mouth (Paused)" : (isSpeaking ? "Mouth (Speaking)" : "Mouth")
    }

    private func startWaveformAnimationIfNeeded() {
        if waveformTimer == nil {
            currentWaveformSymbol = nil
            setStatusItemSymbol(nextWaveformSymbol())

            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.setStatusItemSymbol(self.nextWaveformSymbol())
            }
            RunLoop.main.add(timer, forMode: .common)
            waveformTimer = timer
        }
    }

    private func stopWaveformAnimation() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        currentWaveformSymbol = nil
    }

    private func nextWaveformSymbol() -> String {
        let choices = waveformSymbols.filter { $0 != currentWaveformSymbol }
        let next = choices.randomElement() ?? "waveform.mid"
        currentWaveformSymbol = next
        return next
    }

    private func setStatusItemSymbol(_ name: String) {
        let symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
            ?? NSImage(named: name)?
            .withSymbolConfiguration(symbolConfiguration)
        img?.isTemplate = true
        statusItem.button?.image = img
    }
}
