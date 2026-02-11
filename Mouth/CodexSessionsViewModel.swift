import Foundation
import Combine

final class CodexSessionsViewModel: ObservableObject {
    @Published private(set) var isPaused = false

    private let engine: MouthEngine
    private let announcer: CodexVoiceAnnouncer

    private static let pausedDefaultsKey = "mouth.paused"

    func stopSpeakingAndClearQueue() {
        announcer.stopAll()
    }

    func togglePaused() {
        setPaused(!isPaused)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        UserDefaults.standard.set(paused, forKey: Self.pausedDefaultsKey)
        engine.setPaused(paused)
        announcer.setPaused(paused)
    }

    init(engine: MouthEngine) {
        self.engine = engine
        self.announcer = CodexVoiceAnnouncer()

        let paused = UserDefaults.standard.bool(forKey: Self.pausedDefaultsKey)
        isPaused = paused
        engine.setPaused(paused)
        announcer.setPaused(paused)

        engine.onNewAssistantMessage = { [weak announcer] event in
            Task { @MainActor in
                announcer?.enqueue(event)
            }
        }

        engine.start()
    }

    deinit {
        engine.onNewAssistantMessage = nil
        engine.stop()
        let a = announcer
        Task { @MainActor in
            a.stopAll()
        }
    }
}
