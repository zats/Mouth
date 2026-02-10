import Foundation
import Combine

final class CodexSessionsViewModel: ObservableObject {
    @Published private(set) var sessions: [CodexActiveSession] = []
    @Published private(set) var isPaused = false

    private let engine: MouthEngine
    private let announcer: CodexVoiceAnnouncer

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
        engine.setPaused(paused)
        Task {
            await announcer.setPaused(paused)
        }
    }

    init(engine: MouthEngine) {
        self.engine = engine
        self.announcer = CodexVoiceAnnouncer()

        engine.onSessionsChanged = { [weak self] sessions in
            self?.sessions = sessions
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
