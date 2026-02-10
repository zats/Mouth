import Foundation
import Combine

final class CodexSessionsViewModel: ObservableObject {
    @Published private(set) var isPaused = false

    private let engine: MouthEngine
    private let announcer: CodexVoiceAnnouncer

    private static let pausedDefaultsKey = "mouth.paused"

    func stopSpeakingAndClearQueue() {
        Task {
            await announcer.stopAll()
        }
    }

    func togglePaused() {
        setPaused(!isPaused)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        UserDefaults.standard.set(paused, forKey: Self.pausedDefaultsKey)
        engine.setPaused(paused)
        Task {
            await announcer.setPaused(paused)
        }
    }

    init(engine: MouthEngine) {
        self.engine = engine
        self.announcer = CodexVoiceAnnouncer()

        let paused = UserDefaults.standard.bool(forKey: Self.pausedDefaultsKey)
        isPaused = paused
        engine.setPaused(paused)
        Task {
            await announcer.setPaused(paused)
        }

        engine.onNewAssistantMessage = { [weak self] event in
            guard let self else { return }
            Task {
                await self.announcer.enqueue(event)
            }
        }

        engine.start()
    }

    deinit {
        engine.stop()
        Task {
            await announcer.stopAll()
        }
    }
}
