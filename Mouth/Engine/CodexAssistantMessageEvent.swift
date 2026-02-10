import Foundation

struct CodexAssistantMessageEvent: Hashable, Sendable {
    let sessionID: String?
    let sessionFileURL: URL
    let text: String
    let timestamp: Date?
}
