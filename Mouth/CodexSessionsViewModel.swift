import Foundation
import Combine

final class CodexSessionsViewModel: ObservableObject {
    @Published private(set) var sessions: [CodexActiveSession] = []

    private let engine: MouthEngine

    init(engine: MouthEngine = MouthEngine()) {
        self.engine = engine

        engine.onSessionsChanged = { [weak self] sessions in
            self?.sessions = sessions
        }

        engine.start()
    }

    deinit {
        engine.stop()
    }
}
