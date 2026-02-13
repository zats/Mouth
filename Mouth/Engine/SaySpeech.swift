import AVFoundation
import ApplicationServices
import Foundation
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
    case speechManagerFailure(operation: String, status: Int16)

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
        case let .speechManagerFailure(operation, status):
            return "Speech Manager failed while \(operation) (OSStatus \(Int(status)))"
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

    fileprivate final class SpeechSession: PlaybackController, @unchecked Sendable {
        private let text: String
        private let voiceSpec: VoiceSpec?
        private let rate: Int?

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var terminalResult: Result<Void, Error>?
        private var running = false
        private var channel: SpeechChannel?
        private var monitorTask: Task<Void, Never>?

        init(text: String, voiceSpec: VoiceSpec?, rate: Int?) {
            self.text = text
            self.voiceSpec = voiceSpec
            self.rate = rate
        }

        var isRunning: Bool {
            lock.withLock { running }
        }

        func start() throws {
            var createdChannel: SpeechChannel?

            let createStatus: Int16
            if var selectedVoice = voiceSpec {
                createStatus = withUnsafeMutablePointer(to: &selectedVoice) { voicePointer in
                    NewSpeechChannel(voicePointer, &createdChannel)
                }
            } else {
                createStatus = NewSpeechChannel(nil, &createdChannel)
            }

            guard createStatus == noErr, let createdChannel else {
                throw SaySpeechError.speechManagerFailure(
                    operation: "opening speech channel",
                    status: createStatus
                )
            }

            if let rate {
                let setRateStatus = SetSpeechRate(
                    createdChannel,
                    SaySpeech.mapWordsPerMinuteToSpeechManagerRate(rate)
                )
                guard setRateStatus == noErr else {
                    _ = DisposeSpeechChannel(createdChannel)
                    throw SaySpeechError.speechManagerFailure(
                        operation: "setting speech rate",
                        status: setRateStatus
                    )
                }
            }

            lock.withLock {
                running = true
                channel = createdChannel
            }

            let speakStatus = SpeakCFString(createdChannel, text as CFString, nil)
            guard speakStatus == noErr else {
                lock.withLock {
                    running = false
                    channel = nil
                }
                _ = DisposeSpeechChannel(createdChannel)
                throw SaySpeechError.speechManagerFailure(
                    operation: "speaking text",
                    status: speakStatus
                )
            }

            let task = Task { [weak self] in
                guard let self else {
                    return
                }
                await monitorChannel()
            }

            lock.withLock {
                monitorTask = task
            }
        }

        func cancel() {
            let activeChannel: SpeechChannel? = lock.withLock {
                channel
            }
            guard let activeChannel else { return }

            _ = StopSpeech(activeChannel)
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

        private func monitorChannel() async {
            while true {
                if Task.isCancelled {
                    return
                }

                guard let activeChannel = lock.withLock({ channel }) else {
                    return
                }

                do {
                    if try !isBusy(activeChannel) {
                        finish(.success(()))
                        return
                    }
                } catch {
                    finish(.failure(error))
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 40_000_000)
                } catch {
                    return
                }
            }
        }

        private func isBusy(_ channel: SpeechChannel) throws -> Bool {
            var statusObject: AnyObject?
            let status = CopySpeechProperty(channel, kSpeechStatusProperty, &statusObject)
            guard status == noErr else {
                throw SaySpeechError.speechManagerFailure(
                    operation: "reading speech status",
                    status: status
                )
            }

            guard let statusDictionary = statusObject as? [String: Any] else {
                return false
            }

            return statusDictionary[kSpeechStatusOutputBusy as String] as? Bool ?? false
        }

        private func finish(_ result: Result<Void, Error>) {
            let completionData: (
                continuation: CheckedContinuation<Void, Error>?,
                channel: SpeechChannel?,
                task: Task<Void, Never>?
            ) = lock.withLock {
                guard terminalResult == nil else {
                    return (nil, nil, nil)
                }

                terminalResult = result
                running = false

                let continuation = continuation
                self.continuation = nil

                let channel = channel
                self.channel = nil

                let task = monitorTask
                monitorTask = nil

                return (continuation, channel, task)
            }

            completionData.task?.cancel()

            if let channel = completionData.channel {
                _ = DisposeSpeechChannel(channel)
            }

            completionData.continuation?.resume(with: result)
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
        let selectedVoiceSpec: VoiceSpec?
        if let voice = voice?.trimmingCharacters(in: .whitespacesAndNewlines), !voice.isEmpty {
            guard let resolvedVoiceSpec = resolveSpeechVoiceSpec(for: voice) else {
                throw SaySpeechError.unavailableVoice(voice)
            }
            selectedVoiceSpec = resolvedVoiceSpec
        } else {
            selectedVoiceSpec = nil
        }

        let session = SpeechSession(text: text, voiceSpec: selectedVoiceSpec, rate: rate)
        try session.start()
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

    private func resolveSpeechVoiceSpec(for rawValue: String) -> VoiceSpec? {
        if let explicitSpec = parseVoiceSpecIdentifier(rawValue) {
            return explicitSpec
        }
        return findVoiceSpec(named: rawValue)
    }

    private func parseVoiceSpecIdentifier(_ rawValue: String) -> VoiceSpec? {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }

        guard let creator = parseUInt32(parts[0]),
              let id = parseUInt32(parts[1]) else
        {
            return nil
        }

        return VoiceSpec(creator: creator, id: id)
    }

    private func parseUInt32(_ rawValue: String) -> UInt32? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }

        return UInt32(trimmed)
    }

    private func findVoiceSpec(named rawVoiceName: String) -> VoiceSpec? {
        let normalizedTarget = rawVoiceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedTarget.isEmpty else {
            return nil
        }

        var count: Int16 = 0
        guard CountVoices(&count) == noErr, count > 0 else {
            return nil
        }

        var partialMatch: VoiceSpec?
        for index in 1 ... count {
            var voiceSpec = VoiceSpec()
            guard GetIndVoice(index, &voiceSpec) == noErr else {
                continue
            }
            guard let voiceName = speechVoiceName(for: voiceSpec)?.lowercased() else {
                continue
            }

            if voiceName == normalizedTarget {
                return voiceSpec
            }

            if partialMatch == nil, voiceName.contains(normalizedTarget) {
                partialMatch = voiceSpec
            }
        }

        return partialMatch
    }

    private func speechVoiceName(for voiceSpec: VoiceSpec) -> String? {
        var mutableVoiceSpec = voiceSpec
        var description = VoiceDescription()
        description.length = Int32(MemoryLayout<VoiceDescription>.size)

        let status = withUnsafePointer(to: &mutableVoiceSpec) { voicePointer in
            GetVoiceDescription(voicePointer, &description, MemoryLayout<VoiceDescription>.size)
        }
        guard status == noErr else {
            return nil
        }

        let decodedName = decodePascalString(description.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decodedName.isEmpty ? nil : decodedName
    }

    private func decodePascalString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            guard let first = bytes.first else {
                return ""
            }

            let length = min(Int(first), bytes.count - 1)
            guard length > 0 else {
                return ""
            }

            let payload = bytes.dropFirst().prefix(length)
            if let decoded = String(bytes: payload, encoding: .macOSRoman) {
                return decoded
            }
            return String(decoding: payload, as: UTF8.self)
        }
    }

    private static func mapWordsPerMinuteToSpeechManagerRate(_ wordsPerMinute: Int) -> Int32 {
        let clampedWordsPerMinute = min(max(wordsPerMinute, 1), 0x7FF)
        return Int32(clampedWordsPerMinute << 16)
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
