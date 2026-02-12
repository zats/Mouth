import Foundation

@MainActor
final class HotkeyController {
    private weak var model: CodexSessionsViewModel?
    private var didRegisterHandlers = false

    func bind(model: CodexSessionsViewModel) {
        self.model = model

        guard !didRegisterHandlers else { return }
        didRegisterHandlers = true

        KeyboardShortcuts.onKeyUp(for: .toggleMouthEnabled) { [weak self] in
            self?.model?.togglePaused()
        }

        KeyboardShortcuts.onKeyUp(for: .stopSpeech) { [weak self] in
            guard StopSpeechHotkeyMode.current == .keyboardShortcut else { return }
            self?.model?.stopSpeakingAndClearQueue()
        }
    }
}

enum StopSpeechHotkeyMode: String, CaseIterable {
    case mediaPlayPause
    case keyboardShortcut

    static let defaultsKey = "mouth.hotkey.stop_speech.mode"

    static var current: StopSpeechHotkeyMode {
        // The UI treats "no shortcut" as Play/Pause fallback.
        // Derive mode from actual shortcut presence first so stale persisted mode
        // values cannot disable Play/Pause after clearing the recorder.
        if KeyboardShortcuts.Name.stopSpeech.shortcut != nil {
            return .keyboardShortcut
        }

        let ud = UserDefaults.standard
        guard let raw = ud.string(forKey: defaultsKey) else {
            return .mediaPlayPause
        }
        return StopSpeechHotkeyMode(rawValue: raw) ?? .mediaPlayPause
    }

    var isDefault: Bool {
        self == .mediaPlayPause
    }
}

extension KeyboardShortcuts.Name {
    static let toggleMouthEnabled = Self("mouth.toggle.enabled", default: .init(.f8))
    static let stopSpeech = Self("mouth.stop.speech")
}
