import AVFoundation
import Foundation

@MainActor
final class AppAudioDucker {
    private let engine = AVAudioEngine()
    private var isDucking = false

    func start() {
        guard !isDucking else { return }

        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)

            var config = engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration
            config.enableAdvancedDucking = false
            config.duckingLevel = .default
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = config

            try engine.start()
            isDucking = true
        } catch {
            engine.stop()
            _ = try? engine.inputNode.setVoiceProcessingEnabled(false)
            isDucking = false
        }
    }

    func stop() {
        guard isDucking else { return }

        engine.stop()
        _ = try? engine.inputNode.setVoiceProcessingEnabled(false)
        isDucking = false
    }
}
