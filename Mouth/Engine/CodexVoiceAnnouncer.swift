import Foundation
import FoundationModels

@MainActor
final class CodexVoiceAnnouncer {
    static let duckAudioIfPlayingDefaultsKey = "mouth.pause_external_playback_while_speaking"
    static let summarizeWithPromptDefaultsKey = "mouth.speech.summarize_with_prompt_enabled"
    static let summarizePromptDefaultsKey = "mouth.speech.summarize_with_prompt_text"
    static let defaultSummarizePrompt = "Summarize the message from AI assistnant into one clear sentence under 15 words. Keep only the most important point. Make message addressed from first person. If original messages is under 15 words, return unchanged."

    struct Item: Hashable, Sendable {
        let sessionID: String?
        let sessionFileURL: URL
        let text: String
        let timestamp: Date?
    }

    private let speaker = SaySpeech()
    private let sound = AppSound()
    private let audioDucker = AppAudioDucker()

    private var queue: [Item] = []
    private var runner: Task<Void, Never>?

    private var currentDelimiterPlayback: AppSound.Playback?
    private var currentSpeech: SaySpeech.Playback?
    private var currentItem: Item?

    private var isSpeaking = false
    private var paused = false

    init() {}

    private func shouldDuckAudioIfPlaying() -> Bool {
        let ud = UserDefaults.standard
        if ud.object(forKey: Self.duckAudioIfPlayingDefaultsKey) == nil {
            return true // default enabled
        }
        return ud.bool(forKey: Self.duckAudioIfPlayingDefaultsKey)
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
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
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
        currentDelimiterPlayback?.cancel()
        currentDelimiterPlayback = nil
        currentSpeech?.cancel()
        currentSpeech = nil
        runner?.cancel()
        runner = nil

        audioDucker.stop()
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
            audioDucker.stop()
            setCurrentItem(nil)
            setSpeaking(false)
        }

        if paused {
            return
        }

        setSpeaking(true)

        if shouldDuckAudioIfPlaying() {
            audioDucker.start()
        }

        while !Task.isCancelled {
            guard !queue.isEmpty else {
                return
            }

            let item = queue.removeFirst()
            setCurrentItem(item)

            // Delimiter sound before each spoken message.
            do {
                let p = try sound.play(fileURL: delimiterSoundURL())
                currentDelimiterPlayback = p
                try await p.wait()
                currentDelimiterPlayback = nil
            } catch {
                currentDelimiterPlayback = nil
                if error is CancellationError {
                    return
                }
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
}
