//

import SwiftUI

@main
struct MouthApp: App {
    private let engine = MouthEngine()

    init() {
        engine.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
