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
    static let toggleMouthEnabled = Self("mouth.toggle.enabled")
    static let stopSpeech = Self("mouth.stop.speech")
}
