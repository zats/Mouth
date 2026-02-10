import Foundation

actor CodexVoiceAnnouncer {
    static let pauseExternalPlaybackDefaultsKey = "mouth.pause_external_playback_while_speaking"

    struct Item: Hashable, Sendable {
        let sessionID: String?
        let sessionFileURL: URL
        let text: String
        let timestamp: Date?
    }

    private let speaker = SaySpeech()
    private let sound = AfplaySound()

    private var queue: [Item] = []
    private var runner: Task<Void, Never>?

    private var currentDelimiter: AfplaySound.Playback?
    private var currentSpeech: SaySpeech.Playback?
    private var currentItem: Item?

    private var didPauseExternalPlayback = false
    private var isSpeaking = false
    private var paused = false

    private func shouldPauseExternalPlaybackWhileSpeaking() -> Bool {
        let ud = UserDefaults.standard
        if ud.object(forKey: Self.pauseExternalPlaybackDefaultsKey) == nil {
            return true // default enabled
        }
        return ud.bool(forKey: Self.pauseExternalPlaybackDefaultsKey)
    }

    func enqueue(_ event: AssistantMessageEvent) {
        if paused {
            return
        }

        queue.append(Item(
            sessionID: event.sessionID,
            sessionFileURL: event.sessionFileURL,
            text: event.text,
            timestamp: event.timestamp
        ))

        if runner == nil {
            runner = Task {
                await run()
            }
        }
    }

    func stopAll() {
        queue.removeAll()
        currentDelimiter?.cancel()
        currentDelimiter = nil
        currentSpeech?.cancel()
        currentSpeech = nil
        runner?.cancel()
        runner = nil

        if didPauseExternalPlayback {
            // If we paused someone else's playback at the start of this batch, resume it on stop
            // only when the setting is enabled.
            if shouldPauseExternalPlaybackWhileSpeaking() {
                MediaKeyController.togglePlayPause()
            }
            didPauseExternalPlayback = false
        }

        setCurrentItem(nil)
        setSpeaking(false)
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            stopAll()
        }
    }

    private func run() async {
        defer {
            runner = nil
            setCurrentItem(nil)
            setSpeaking(false)
        }

        if paused {
            return
        }

        setSpeaking(true)

        // Pause external playback once for the whole batch (best-effort).
        if shouldPauseExternalPlaybackWhileSpeaking(),
           !didPauseExternalPlayback,
           SystemAudioActivity.isAnyOtherProcessRunningOutput()
        {
            MediaKeyController.togglePlayPause()
            didPauseExternalPlayback = true

            // Give the target player a moment to react before we play our delimiter/speech.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        while !Task.isCancelled {
            guard !queue.isEmpty else {
                if didPauseExternalPlayback {
                    if shouldPauseExternalPlaybackWhileSpeaking() {
                        MediaKeyController.togglePlayPause()
                    }
                    didPauseExternalPlayback = false
                }
                return
            }

            let item = queue.removeFirst()
            setCurrentItem(item)

            // Delimiter sound before each spoken message.
            if let url = delimiterSoundURL() {
                do {
                    let p = try sound.play(fileURL: url)
                    currentDelimiter = p
                    try await p.wait()
                } catch {
                    // Non-fatal; continue to speech.
                }
            }
            currentDelimiter = nil

            do {
                let p = try speaker.play(item.text)
                currentSpeech = p
                try await p.wait()
            } catch {
                // Non-fatal; continue with next queued item.
            }
            currentSpeech = nil
        }
    }

    private func delimiterSoundURL() -> URL? {
        Bundle.main.url(forResource: "codex_delimiter", withExtension: "wav")
    }

    private func setSpeaking(_ speaking: Bool) {
        if isSpeaking == speaking { return }
        isSpeaking = speaking
        NotificationCenter.default.post(
            name: .codexVoiceAnnouncerSpeakingChanged,
            object: nil,
            userInfo: ["speaking": speaking]
        )
    }

    private func setCurrentItem(_ item: Item?) {
        if currentItem == item { return }
        currentItem = item

        var info: [AnyHashable: Any] = [:]
        if let id = item?.sessionID {
            info["sessionID"] = id
        }

        NotificationCenter.default.post(
            name: .codexVoiceAnnouncerCurrentItemChanged,
            object: nil,
            userInfo: info
        )
    }
}
