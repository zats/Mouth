import Foundation

enum MouthSessionSource: String, CaseIterable, Hashable, Sendable {
    case codex
    case claudeCode
}

struct MouthDiscoveredSession: Hashable, Sendable {
    let source: MouthSessionSource
    let sessionID: String?
    let fileURL: URL
    let owners: Set<String>
}

struct MouthAssistantMessage: Hashable, Sendable {
    let text: String
    let at: Date?
}

protocol MouthSessionProvider {
    var source: MouthSessionSource { get }

    /// Returns sessions that should be monitored right now.
    func discoverSessions() -> [MouthDiscoveredSession]

    /// Parses a JSONL line into an assistant message for this provider, or nil.
    func parseAssistantMessage(dict: [String: Any], iso: ISO8601DateFormatter) -> MouthAssistantMessage?
}

