import AVFoundation
import Foundation
import NaturalLanguage
import Security

enum SaySpeechError: Error, LocalizedError {
    case cancelled
    case emptyText
    case unavailableVoice(String)
    case audioPlaybackFailed
    case missingElevenLabsAPIKey
    case elevenLabsNoVoicesAvailable
    case elevenLabsRequestFailed(statusCode: Int, message: String)
    case invalidElevenLabsResponse

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Speech playback was cancelled"
        case .emptyText:
            return "Speech text was empty"
        case let .unavailableVoice(voice):
            return "Requested voice is unavailable: \(voice)"
        case .audioPlaybackFailed:
            return "Failed to start audio playback"
        case .missingElevenLabsAPIKey:
            return "Missing ElevenLabs API key"
        case .elevenLabsNoVoicesAvailable:
            return "No ElevenLabs voices are available for this account"
        case let .elevenLabsRequestFailed(statusCode, message):
            return "ElevenLabs request failed (\(statusCode)): \(message)"
        case .invalidElevenLabsResponse:
            return "Invalid response from ElevenLabs"
        }
    }
}

/// Wrapper around first-party macOS speech synthesis and native ElevenLabs HTTP TTS.
final class SaySpeech {
    enum Provider: String, CaseIterable, Identifiable {
        case macOS = "macos_speech"
        case elevenLabs = "elevenlabs"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .macOS:
                return "macOS speech"
            case .elevenLabs:
                return "ElevenLabs"
            }
        }
    }

    static let providerDefaultsKey = "mouth.speech.provider"
    static let elevenLabsVoiceDefaultsKey = "mouth.speech.elevenlabs.voice_id"

    private static let elevenLabsBaseURL = URL(string: "https://api.elevenlabs.io")!
    private static let elevenLabsDefaultModelID = "eleven_v3"
    private static let elevenLabsDefaultOutputFormat = "mp3_44100_128"
    private static let elevenLabsDefaultWPM = 175

    private static let keychainService = "com.zats.Mouth"
    private static let elevenLabsAPIKeyAccount = "elevenlabs-api-key"
    private static let legacySAGAPIKeyAccount = "sag-elevenlabs-api-key"

    private static let defaultVoiceCacheLock = NSLock()
    private static var cachedDefaultElevenLabsVoiceID: String?

    static func preferredProvider() -> Provider {
        let raw = UserDefaults.standard.string(forKey: providerDefaultsKey)
        if let provider = Provider(rawValue: raw ?? "") {
            return provider
        }

        switch raw {
        case "sag":
            return .elevenLabs
        case "macos_say":
            return .macOS
        default:
            return .macOS
        }
    }

    static func setPreferredProvider(_ provider: Provider) {
        UserDefaults.standard.set(provider.rawValue, forKey: providerDefaultsKey)
    }

    static func preferredElevenLabsVoiceID() -> String? {
        let raw = UserDefaults.standard.string(forKey: elevenLabsVoiceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func setPreferredElevenLabsVoiceID(_ voiceID: String?) {
        let trimmed = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: elevenLabsVoiceDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: elevenLabsVoiceDefaultsKey)
        }
        defaultVoiceCacheLock.withLock {
            cachedDefaultElevenLabsVoiceID = nil
        }
    }

    static func hasElevenLabsAPIKey() -> Bool {
        (try? loadElevenLabsAPIKey()) != nil
    }

    static func setElevenLabsAPIKey(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try upsertKeychainString(
            value,
            service: keychainService,
            account: elevenLabsAPIKeyAccount
        )

        if value == nil {
            try? upsertKeychainString(nil, service: keychainService, account: legacySAGAPIKeyAccount)
        }
    }

    // Internal so Settings UI can display whether a key exists.
    static func loadElevenLabsAPIKey() throws -> String? {
        if let key = try loadKeychainString(service: keychainService, account: elevenLabsAPIKeyAccount) {
            return key
        }
        return try loadKeychainString(service: keychainService, account: legacySAGAPIKeyAccount)
    }

    final class Playback: @unchecked Sendable {
        let id: UUID

        private let controller: any PlaybackController

        fileprivate init(id: UUID, controller: any PlaybackController) {
            self.id = id
            self.controller = controller
        }

        deinit {
            cancel()
        }

        var isRunning: Bool {
            controller.isRunning
        }

        func cancel() {
            controller.cancel()
        }

        func wait() async throws {
            try await controller.wait()
        }
    }

    fileprivate protocol PlaybackController: AnyObject {
        var isRunning: Bool { get }
        func cancel()
        func wait() async throws
    }

    fileprivate final class SpeechSession: NSObject, AVSpeechSynthesizerDelegate, PlaybackController, @unchecked Sendable {
        private let synthesizer = AVSpeechSynthesizer()
        private let utterance: AVSpeechUtterance

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var terminalResult: Result<Void, Error>?
        private var running = false

        init(utterance: AVSpeechUtterance) {
            self.utterance = utterance
            super.init()
            synthesizer.delegate = self
        }

        var isRunning: Bool {
            lock.withLock { running }
        }

        func start() {
            lock.withLock {
                running = true
            }

            runOnMain {
                synthesizer.speak(utterance)
            }
        }

        func cancel() {
            let shouldStop = lock.withLock { running }
            guard shouldStop else { return }

            runOnMain {
                _ = synthesizer.stopSpeaking(at: .immediate)
            }
        }

        func wait() async throws {
            try await withCheckedThrowingContinuation { cont in
                let immediate: Result<Void, Error>? = lock.withLock {
                    if let terminalResult {
                        return terminalResult
                    }
                    continuation = cont
                    return nil
                }

                if let immediate {
                    cont.resume(with: immediate)
                }
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            let continuationToResume: CheckedContinuation<Void, Error>? = lock.withLock {
                guard terminalResult == nil else { return nil }
                terminalResult = result
                running = false

                let cont = continuation
                continuation = nil
                return cont
            }

            runOnMain {
                synthesizer.delegate = nil
            }

            continuationToResume?.resume(with: result)
        }

        private func runOnMain(_ action: () -> Void) {
            if Thread.isMainThread {
                action()
            } else {
                DispatchQueue.main.sync(execute: action)
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            finish(.success(()))
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            finish(.failure(SaySpeechError.cancelled))
        }
    }

    fileprivate final class ElevenLabsSession: NSObject, AVAudioPlayerDelegate, PlaybackController, @unchecked Sendable {
        private struct VoicesResponse: Decodable {
            struct Voice: Decodable {
                let voice_id: String
                let name: String
            }

            let voices: [Voice]
        }

        private struct TTSRequestPayload: Encodable {
            struct VoiceSettings: Encodable {
                let speed: Double
            }

            let text: String
            let model_id: String
            let output_format: String
            let voice_settings: VoiceSettings
        }

        private let text: String
        private let voiceHint: String?
        private let wordsPerMinute: Int?
        private let apiKey: String
        private let preferredVoiceID: String?
        private let session: URLSession

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var terminalResult: Result<Void, Error>?
        private var running = false
        private var requestTask: Task<Void, Never>?
        private var player: AVAudioPlayer?

        init(
            text: String,
            voiceHint: String?,
            wordsPerMinute: Int?,
            apiKey: String,
            preferredVoiceID: String?,
            session: URLSession = .shared
        ) {
            self.text = text
            self.voiceHint = voiceHint
            self.wordsPerMinute = wordsPerMinute
            self.apiKey = apiKey
            self.preferredVoiceID = preferredVoiceID
            self.session = session
        }

        var isRunning: Bool {
            lock.withLock { running }
        }

        func start() {
            lock.withLock {
                running = true
            }

            requestTask = Task {
                await performRequest()
            }
        }

        func cancel() {
            let (task, player): (Task<Void, Never>?, AVAudioPlayer?) = lock.withLock {
                (requestTask, self.player)
            }

            task?.cancel()
            try? runOnMain {
                player?.stop()
            }
            finish(.failure(SaySpeechError.cancelled))
        }

        func wait() async throws {
            try await withCheckedThrowingContinuation { cont in
                let immediate: Result<Void, Error>? = lock.withLock {
                    if let terminalResult {
                        return terminalResult
                    }
                    continuation = cont
                    return nil
                }

                if let immediate {
                    cont.resume(with: immediate)
                }
            }
        }

        private func performRequest() async {
            do {
                let voiceID = try await resolveVoiceID()
                let request = try buildTTSRequest(voiceID: voiceID)
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                try validateTTSResponse(response: response, data: data)
                try startPlayback(with: data)
            } catch is CancellationError {
                finish(.failure(SaySpeechError.cancelled))
            } catch {
                finish(.failure(error))
            }
        }

        private func resolveVoiceID() async throws -> String {
            if let voiceHint = voiceHint?.trimmingCharacters(in: .whitespacesAndNewlines), !voiceHint.isEmpty {
                if looksLikeVoiceID(voiceHint) {
                    return voiceHint
                }
                if let matchedID = try await resolveVoiceIDByName(voiceHint) {
                    return matchedID
                }
                return voiceHint
            }

            if let preferredVoiceID, !preferredVoiceID.isEmpty {
                return preferredVoiceID
            }

            if let cached = SaySpeech.defaultVoiceCacheLock.withLock({ SaySpeech.cachedDefaultElevenLabsVoiceID }) {
                return cached
            }

            let voices = try await fetchVoices()
            guard let firstVoice = voices.first else {
                throw SaySpeechError.elevenLabsNoVoicesAvailable
            }
            SaySpeech.defaultVoiceCacheLock.withLock {
                SaySpeech.cachedDefaultElevenLabsVoiceID = firstVoice.voice_id
            }
            return firstVoice.voice_id
        }

        private func resolveVoiceIDByName(_ voiceName: String) async throws -> String? {
            let voices = try await fetchVoices()
            let lowered = voiceName.lowercased()

            if let exact = voices.first(where: { $0.name.lowercased() == lowered }) {
                return exact.voice_id
            }

            if let partial = voices.first(where: { $0.name.lowercased().contains(lowered) }) {
                return partial.voice_id
            }

            return nil
        }

        private func fetchVoices() async throws -> [VoicesResponse.Voice] {
            var request = URLRequest(url: SaySpeech.elevenLabsBaseURL.appending(path: "/v1/voices"))
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SaySpeechError.invalidElevenLabsResponse
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw SaySpeechError.elevenLabsRequestFailed(
                    statusCode: httpResponse.statusCode,
                    message: responseMessage(from: data)
                )
            }

            let parsed = try JSONDecoder().decode(VoicesResponse.self, from: data)
            return parsed.voices
        }

        private func buildTTSRequest(voiceID: String) throws -> URLRequest {
            var request = URLRequest(
                url: SaySpeech.elevenLabsBaseURL.appending(path: "/v1/text-to-speech/\(voiceID)")
            )
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

            let speed = mapWordsPerMinuteToElevenLabsSpeed(wordsPerMinute)
            let payload = TTSRequestPayload(
                text: text,
                model_id: SaySpeech.elevenLabsDefaultModelID,
                output_format: SaySpeech.elevenLabsDefaultOutputFormat,
                voice_settings: .init(speed: speed)
            )
            request.httpBody = try JSONEncoder().encode(payload)
            return request
        }

        private func validateTTSResponse(response: URLResponse, data: Data) throws {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SaySpeechError.invalidElevenLabsResponse
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw SaySpeechError.elevenLabsRequestFailed(
                    statusCode: httpResponse.statusCode,
                    message: responseMessage(from: data)
                )
            }

            guard !data.isEmpty else {
                throw SaySpeechError.invalidElevenLabsResponse
            }
        }

        private func responseMessage(from data: Data) -> String {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "No response body" : text
        }

        private func startPlayback(with data: Data) throws {
            let audioPlayer = try runOnMain { try AVAudioPlayer(data: data) }

            try runOnMain {
                audioPlayer.delegate = self
                audioPlayer.prepareToPlay()
                guard audioPlayer.play() else {
                    throw SaySpeechError.audioPlaybackFailed
                }
            }

            lock.withLock {
                player = audioPlayer
            }
        }

        private func runOnMain<T>(_ action: () throws -> T) throws -> T {
            if Thread.isMainThread {
                return try action()
            }
            return try DispatchQueue.main.sync(execute: action)
        }

        private func mapWordsPerMinuteToElevenLabsSpeed(_ wordsPerMinute: Int?) -> Double {
            let wpm = wordsPerMinute ?? SaySpeech.elevenLabsDefaultWPM
            let rawSpeed = Double(wpm) / Double(SaySpeech.elevenLabsDefaultWPM)
            return min(max(rawSpeed, 0.5), 2.0)
        }

        private func finish(_ result: Result<Void, Error>) {
            let continuationToResume: CheckedContinuation<Void, Error>? = lock.withLock {
                guard terminalResult == nil else { return nil }
                terminalResult = result
                running = false

                let cont = continuation
                continuation = nil
                requestTask = nil
                player = nil
                return cont
            }

            continuationToResume?.resume(with: result)
        }

        private func looksLikeVoiceID(_ value: String) -> Bool {
            value.count >= 15 && !value.contains(" ")
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            finish(.success(()))
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            finish(.failure(error ?? SaySpeechError.audioPlaybackFailed))
        }
    }

    func play(
        _ text: String,
        voice: String? = nil,
        rate: Int? = nil
    ) throws -> Playback {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SaySpeechError.emptyText
        }

        let provider = Self.preferredProvider()

        if provider == .elevenLabs {
            guard let apiKey = (try? Self.loadElevenLabsAPIKey())?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else
            {
                throw SaySpeechError.missingElevenLabsAPIKey
            }
            return playElevenLabs(trimmed, voice: voice, rate: rate, apiKey: apiKey)
        }

        return try playMacOS(trimmed, voice: voice, rate: rate)
    }

    private func playMacOS(
        _ text: String,
        voice: String?,
        rate: Int?
    ) throws -> Playback {
        let utterance = AVSpeechUtterance(string: text)

        if let voice, !voice.isEmpty {
            guard let resolvedVoice = resolveMacOSVoice(for: voice) else {
                throw SaySpeechError.unavailableVoice(voice)
            }
            utterance.voice = resolvedVoice
        } else if let bestVoice = bestAvailableMacOSVoice(for: text) {
            utterance.voice = bestVoice
        }

        if let rate {
            utterance.rate = mapWordsPerMinuteToAVRate(rate)
        }

        let session = SpeechSession(utterance: utterance)
        session.start()
        return Playback(id: UUID(), controller: session)
    }

    private func playElevenLabs(
        _ text: String,
        voice: String?,
        rate: Int?,
        apiKey: String
    ) -> Playback {
        let session = ElevenLabsSession(
            text: text,
            voiceHint: voice,
            wordsPerMinute: rate,
            apiKey: apiKey,
            preferredVoiceID: Self.preferredElevenLabsVoiceID()
        )
        session.start()
        return Playback(id: UUID(), controller: session)
    }

    private func resolveMacOSVoice(for rawValue: String) -> AVSpeechSynthesisVoice? {
        if let byIdentifier = AVSpeechSynthesisVoice(identifier: rawValue) {
            return byIdentifier
        }

        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        return AVSpeechSynthesisVoice.speechVoices().first {
            $0.name.lowercased() == normalized
                || $0.language.lowercased() == normalized
                || $0.identifier.lowercased() == normalized
        }
    }

    private func bestAvailableMacOSVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard !voices.isEmpty else { return nil }

        let preferredLanguageCodes = prioritizedLanguageCodes(for: text)
        let rankedVoices = voices
            .map { voice in
                (voice: voice, score: score(voice: voice, preferredLanguageCodes: preferredLanguageCodes))
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.voice.identifier < rhs.voice.identifier
            }

        return rankedVoices.first?.voice
    }

    private func prioritizedLanguageCodes(for text: String) -> [String] {
        var prioritized: [String] = []

        if let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue {
            prioritized.append(detected)
        }

        prioritized.append(AVSpeechSynthesisVoice.currentLanguageCode())
        prioritized.append(contentsOf: Locale.preferredLanguages)

        var seen = Set<String>()
        var normalized: [String] = []
        for code in prioritized {
            let normalizedCode = normalizeLanguageCode(code)
            guard !normalizedCode.isEmpty else { continue }
            guard seen.insert(normalizedCode).inserted else { continue }
            normalized.append(normalizedCode)
        }
        return normalized
    }

    private func score(voice: AVSpeechSynthesisVoice, preferredLanguageCodes: [String]) -> Int {
        var score = 0

        switch voice.quality {
        case .premium:
            score += 1200
        case .enhanced:
            score += 800
        default:
            score += 400
        }

        if voice.voiceTraits.contains(.isNoveltyVoice) {
            score -= 1200
        } else {
            score += 120
        }

        let identifier = voice.identifier.lowercased()
        if identifier.contains(".eloquence.") {
            score -= 900
        }
        if identifier.contains(".speech.synthesis.voice.") {
            score -= 900
        }
        if identifier.contains("siri") {
            score += 300
        }

        let voiceLanguage = normalizeLanguageCode(voice.language)
        let voicePrimaryLanguage = primaryLanguage(from: voiceLanguage)

        for (index, preferredLanguage) in preferredLanguageCodes.enumerated() {
            let priorityWeight = max(0, 80 - (index * 10))
            if voiceLanguage == preferredLanguage {
                score += 350 + priorityWeight
                break
            }

            let preferredPrimaryLanguage = primaryLanguage(from: preferredLanguage)
            if !preferredPrimaryLanguage.isEmpty,
               preferredPrimaryLanguage == voicePrimaryLanguage
            {
                score += 220 + priorityWeight
                break
            }
        }

        return score
    }

    private func normalizeLanguageCode(_ code: String) -> String {
        code
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func primaryLanguage(from code: String) -> String {
        normalizeLanguageCode(code).split(separator: "-").first.map(String.init) ?? ""
    }

    private func mapWordsPerMinuteToAVRate(_ wordsPerMinute: Int) -> Float {
        let clampedWordsPerMinute = min(max(wordsPerMinute, 80), 450)
        let normalized = Float(clampedWordsPerMinute - 80) / Float(450 - 80)

        return AVSpeechUtteranceMinimumSpeechRate
            + normalized * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate)
    }

    private static func loadKeychainString(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }
        guard let data = item as? Data else {
            return nil
        }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    private static func upsertKeychainString(_ value: String?, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if value == nil {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                return
            }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }

        guard let data = value?.data(using: .utf8) else {
            return
        }

        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }

        var add = query
        add[kSecValueData as String] = data

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: nil)
        }
    }
}
