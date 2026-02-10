import Foundation

final class ClaudeCodeSessionProvider: MouthSessionProvider {
    let source: MouthSessionSource = .claudeCode

    private let logger: (String) -> Void
    private let maxSessions: Int
    private let scanInterval: TimeInterval

    private var lastScanAt: Date?
    private var cached: [MouthDiscoveredSession] = []

    init(logger: @escaping (String) -> Void, maxSessions: Int = 24, scanInterval: TimeInterval = 5) {
        self.logger = logger
        self.maxSessions = maxSessions
        self.scanInterval = scanInterval
    }

    func discoverSessions() -> [MouthDiscoveredSession] {
        let now = Date()
        if let lastScanAt, now.timeIntervalSince(lastScanAt) < scanInterval {
            return cached
        }
        lastScanAt = now

        let fm = FileManager.default
        let baseURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: baseURL.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        // There can be thousands of sessions; keep only the N most recently modified as we scan.
        struct Candidate {
            let url: URL
            let mtime: Date
        }

        var top: [Candidate] = []
        top.reserveCapacity(maxSessions)

        func insert(_ c: Candidate) {
            if top.count < maxSessions {
                top.append(c)
                return
            }
            // Find current minimum and replace if newer.
            var minIdx = 0
            for i in 1..<top.count {
                if top[i].mtime < top[minIdx].mtime {
                    minIdx = i
                }
            }
            if c.mtime > top[minIdx].mtime {
                top[minIdx] = c
            }
        }

        if let e = fm.enumerator(at: baseURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in e {
                if fileURL.pathExtension.lowercased() != "jsonl" { continue }
                let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                insert(Candidate(url: fileURL, mtime: mtime))
            }
        }

        if top.isEmpty { return [] }

        top.sort { $0.mtime > $1.mtime }

        let sessions = top.map { item in
            let sessionID = item.url.deletingPathExtension().lastPathComponent
            return MouthDiscoveredSession(
                source: .claudeCode,
                sessionID: sessionID.isEmpty ? nil : sessionID,
                fileURL: item.url,
                owners: ["filesystem"]
            )
        }

        cached = sessions
        logger("claude discover sessions=\(sessions.count)")
        return sessions
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
