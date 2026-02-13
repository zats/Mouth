import Foundation
import FoundationModels
import Darwin

@MainActor
final class CodexVoiceAnnouncer {
    static let pauseExternalPlaybackDefaultsKey = "mouth.pause_external_playback_while_speaking"
    static let summarizeWithPromptDefaultsKey = "mouth.speech.summarize_with_prompt_enabled"
    static let summarizePromptDefaultsKey = "mouth.speech.summarize_with_prompt_text"
    static let defaultSummarizePrompt = "Summarize the message from AI assistnant into one clear sentence under 20 words. Keep only the most important point. Make message addressed from first person. If original messages is under 20 words, return unchanged."

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
    private var pausedExternalPlaybackPIDs = Set<pid_t>()

    init() {}

    private func shouldPauseExternalPlaybackWhileSpeaking() -> Bool {
        let ud = UserDefaults.standard
        if ud.object(forKey: Self.pauseExternalPlaybackDefaultsKey) == nil {
            return true // default enabled
        }
        return ud.bool(forKey: Self.pauseExternalPlaybackDefaultsKey)
    }

    private func shouldSummarizeBeforeSpeaking() -> Bool {
        let ud = UserDefaults.standard
        if ud.object(forKey: Self.summarizeWithPromptDefaultsKey) == nil {
            return true // default enabled
        }
        return ud.bool(forKey: Self.summarizeWithPromptDefaultsKey)
    }

    private func activeSummaryPrompt() -> String {
        let raw = UserDefaults.standard.string(forKey: Self.summarizePromptDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? Self.defaultSummarizePrompt : raw
    }

    private func textForSpeech(from item: Item) async -> String {
        let original = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return item.text }
        guard shouldSummarizeBeforeSpeaking() else { return original }

        let prompt = activeSummaryPrompt()
        guard let summarized = await summarizeWithFoundationModel(text: original, prompt: prompt) else {
            return original
        }

        let cleaned = summarized.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? original : cleaned
    }

    private func summarizeWithFoundationModel(text: String, prompt: String) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

        let session = LanguageModelSession(model: model, instructions: prompt)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 40)

        do {
            let response = try await session.respond(to: text, options: options)
            return response.content
        } catch {
            return nil
        }
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
           let externalPlaybackPIDs = SystemAudioActivity.otherProcessesRunningOutput(),
           !externalPlaybackPIDs.isEmpty
        {
            MediaKeyController.togglePlayPause()
            didPauseExternalPlayback = true
            pausedExternalPlaybackPIDs = externalPlaybackPIDs

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
            do {
                let p = try sound.play(fileURL: delimiterSoundURL())
                try await p.wait()
            } catch {
                fatalError("\(error)")
            }

            do {
                let textToSpeak = await textForSpeech(from: item)
                let p = try speaker.play(textToSpeak)
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

        let targetPIDs = pausedExternalPlaybackPIDs
        pausedExternalPlaybackPIDs.removeAll()
        didPauseExternalPlayback = false

        guard shouldPauseExternalPlaybackWhileSpeaking(),
              !targetPIDs.isEmpty,
              targetPIDs.allSatisfy(isRunningProcess)
        else {
            return
        }

        // Don’t resume unless we can prove no output is currently active.
        guard let runningPIDs = SystemAudioActivity.otherProcessesRunningOutput(),
              runningPIDs.isEmpty
        else {
            return
        }

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

    private func delimiterSoundURL() -> URL {
        Bundle.main.url(forResource: "delimiter", withExtension: "wav")!
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

    private func isRunningProcess(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
