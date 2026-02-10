import Foundation

final class ClaudeCodeSessionProvider: MouthSessionProvider {
    let source: MouthSessionSource = .claudeCode

    private let logger: (String) -> Void
    private let maxSessions: Int

    init(logger: @escaping (String) -> Void, maxSessions: Int = 24) {
        self.logger = logger
        self.maxSessions = maxSessions
    }

    func discoverSessions() -> [MouthDiscoveredSession] {
        let fm = FileManager.default
        let baseURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: baseURL.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var candidates: [(url: URL, mtime: Date)] = []

        if let e = fm.enumerator(at: baseURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in e {
                if fileURL.pathExtension.lowercased() != "jsonl" { continue }
                let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((url: fileURL, mtime: mtime))
            }
        }

        if candidates.isEmpty { return [] }

        candidates.sort { $0.mtime > $1.mtime }
        let top = candidates.prefix(maxSessions)

        return top.map { item in
            let sessionID = item.url.deletingPathExtension().lastPathComponent
            return MouthDiscoveredSession(
                source: .claudeCode,
                sessionID: sessionID.isEmpty ? nil : sessionID,
                fileURL: item.url,
                owners: ["filesystem"]
            )
        }
    }

    func parseAssistantMessage(dict: [String: Any], iso: ISO8601DateFormatter) -> MouthAssistantMessage? {
        guard (dict["type"] as? String) == "assistant" else { return nil }
        guard let message = dict["message"] as? [String: Any] else { return nil }
        guard (message["type"] as? String) == "message" else { return nil }
        guard (message["role"] as? String) == "assistant" else { return nil }

        guard let content = message["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { item -> String? in
            guard (item["type"] as? String) == "text" else { return nil }
            return item["text"] as? String
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty { return nil }

        let at: Date?
        if let ts = dict["timestamp"] as? String {
            at = iso.date(from: ts)
        } else {
            at = nil
        }

        return MouthAssistantMessage(text: joined, at: at)
    }
}

