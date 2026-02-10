import Foundation

struct AssistantMessageEvent: Hashable, Sendable {
    let source: MouthSessionSource
    let sessionID: String?
    let sessionFileURL: URL
    let text: String
    let timestamp: Date?
}
