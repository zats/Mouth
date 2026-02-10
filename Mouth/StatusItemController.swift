import AppKit
import Foundation

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let stopHandler: () -> Void

    private var speakingObserver: NSObjectProtocol?

    init(stopHandler: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.stopHandler = stopHandler
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(didClick)
            button.imagePosition = .imageOnly
            button.toolTip = "Mouth"
        }

        updateIcon(isSpeaking: false)

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
        stopHandler()
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
