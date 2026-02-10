//

import SwiftUI

@main
struct MouthApp: App {
    @StateObject private var sessionsModel: CodexSessionsViewModel
    private let statusItemController: StatusItemController

    init() {
        let engine = MouthEngine()
        let model = CodexSessionsViewModel(engine: engine)
        _sessionsModel = StateObject(wrappedValue: model)

        statusItemController = StatusItemController(stopHandler: {
            model.stopSpeakingAndClearQueue()
        })
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: sessionsModel)
        }
    }
}
