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
        let hasKeyboardShortcut = KeyboardShortcuts.Name.stopSpeech.shortcut != nil

        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let persisted = StopSpeechHotkeyMode(rawValue: raw)
        {
            if persisted == .keyboardShortcut {
                return hasKeyboardShortcut ? .keyboardShortcut : .mediaPlayPause
            }
            return .mediaPlayPause
        }

        // Legacy installs may have a shortcut set but no explicit mode persisted yet.
        return hasKeyboardShortcut ? .keyboardShortcut : .mediaPlayPause
    }

    var isDefault: Bool {
        self == .mediaPlayPause
    }
}

extension KeyboardShortcuts.Name {
    static let toggleMouthEnabled = Self("mouth.toggle.enabled", default: .init(.f8))
    static let stopSpeech = Self("mouth.stop.speech")
}
