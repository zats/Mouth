import Foundation

@MainActor
final class CodexVoiceAnnouncer {
    static let pauseExternalPlaybackDefaultsKey = "mouth.pause_external_playback_while_speaking"

    struct Item: Hashable, Sendable {
        let sessionID: String?
        let sessionFileURL: URL
        let text: String
        let timestamp: Date?
    }

    private let speaker = SaySpeech()
    private let sound = AppSound()

    private var queue: [Item] = []
    private var runner: Task<Void, Never>?

    private var currentSpeech: SaySpeech.Playback?
    private var currentItem: Item?

    private var didPauseExternalPlayback = false
    private var pendingExternalResumeTask: Task<Void, Never>?
    private var isSpeaking = false
    private var paused = false

    init() {}

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
                await self.run()
            }
        }
    }

    func stopAll() {
        queue.removeAll()
        currentSpeech?.cancel()
        currentSpeech = nil
        runner?.cancel()
        runner = nil

        resumeExternalPlaybackIfNeeded()
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

        pendingExternalResumeTask?.cancel()
        pendingExternalResumeTask = nil

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
                resumeExternalPlaybackIfNeeded()
                return
            }

            let item = queue.removeFirst()
            setCurrentItem(item)

            // Delimiter sound before each spoken message.
            if let url = delimiterSoundURL() {
                do {
                    let p = try sound.play(fileURL: url)
                    try await p.wait()
                } catch {
                    // Non-fatal; continue to speech.
                }
            }

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

    private func resumeExternalPlaybackIfNeeded() {
        guard didPauseExternalPlayback else { return }
        didPauseExternalPlayback = false

        guard shouldPauseExternalPlaybackWhileSpeaking() else { return }

        // Turn off speaking first so the media-key interceptor is disabled before we resume.
        setSpeaking(false)

        pendingExternalResumeTask?.cancel()
        pendingExternalResumeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard !Task.isCancelled else { return }
            MediaKeyController.togglePlayPause()
            self.pendingExternalResumeTask = nil
        }
    }

    private func delimiterSoundURL() -> URL? {
        Bundle.main.url(forResource: "delimiter", withExtension: "wav")
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
