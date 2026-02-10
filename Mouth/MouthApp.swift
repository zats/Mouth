//

import SwiftUI

@main
struct MouthApp: App {
    @StateObject private var sessionsModel = CodexSessionsViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: sessionsModel)
        }
    }
}
