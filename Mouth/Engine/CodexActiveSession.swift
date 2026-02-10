import Foundation

struct CodexActiveSession: Identifiable, Hashable {
    // Stable identity for SwiftUI. Prefer sessionID, else fall back to file path.
    var id: String { sessionID ?? fileURL.path }

    let sessionID: String?
    let fileURL: URL
    let pids: [pid_t]
    let lastChangeAt: Date?
    let fileModificationDate: Date?
    let fileSizeBytes: UInt64?
    let latestAssistantText: String?
    let latestAssistantAt: Date?
}
