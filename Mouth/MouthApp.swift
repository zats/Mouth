//

import SwiftUI

@main
struct MouthApp: App {
    @StateObject private var sessionsModel: CodexSessionsViewModel

    init() {
        let engine = MouthEngine()
        _sessionsModel = StateObject(wrappedValue: CodexSessionsViewModel(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: sessionsModel)
        }
    }
}
