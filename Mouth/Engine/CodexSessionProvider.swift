import Foundation

final class CodexSessionProvider: MouthSessionProvider {
    let source: MouthSessionSource = .codex

    private let logger: (String) -> Void
    private var lastNoSessionLogAtByPid: [pid_t: Date] = [:]

    init(logger: @escaping (String) -> Void) {
        self.logger = logger
    }

    func discoverSessions() -> [MouthDiscoveredSession] {
        let snapshot = ProcessSnapshot.capture()

        let codexProcs = snapshot.byPid.values
            .filter { isCodexLikeProcess($0) }

        var byPath: [String: MouthDiscoveredSession] = [:]
        byPath.reserveCapacity(4)

        for proc in codexProcs {
            do {
                guard let sessionURL = try ProcOpenFiles.findCodexSessionFile(pid: proc.pid) else {
                    maybeLogNoSession(pid: proc.pid)
                    continue
                }

                let path = sessionURL.path
                let id = ProcOpenFiles.extractSessionID(fromSessionFileURL: sessionURL)

                if let existing = byPath[path] {
                    byPath[path] = MouthDiscoveredSession(
                        source: existing.source,
                        sessionID: existing.sessionID ?? id,
                        fileURL: existing.fileURL,
                        owners: existing.owners.union([String(proc.pid)])
                    )
                } else {
                    byPath[path] = MouthDiscoveredSession(
                        source: .codex,
                        sessionID: id,
                        fileURL: sessionURL,
                        owners: [String(proc.pid)]
                    )
                }
            } catch {
                logger("codex pid=\(proc.pid) failed to inspect open files: \(error)")
            }
        }

        return Array(byPath.values)
    }

    func parseAssistantMessage(dict: [String: Any], iso: ISO8601DateFormatter) -> MouthAssistantMessage? {
        guard (dict["type"] as? String) == "response_item" else { return nil }
        guard let payload = dict["payload"] as? [String: Any] else { return nil }
        guard (payload["type"] as? String) == "message" else { return nil }
        guard (payload["role"] as? String) == "assistant" else { return nil }

        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { item -> String? in
            guard (item["type"] as? String) == "output_text" else { return nil }
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

    private func maybeLogNoSession(pid: pid_t) {
        let now = Date()
        if let last = lastNoSessionLogAtByPid[pid], now.timeIntervalSince(last) < 10 {
            return
        }
        lastNoSessionLogAtByPid[pid] = now
        logger("codex pid=\(pid) has no open session file under ~/.codex/sessions")
    }

    private func isCodexLikeProcess(_ p: ProcessSnapshot.ProcessInfo) -> Bool {
        let name = p.name.lowercased()
        if name == "codex" || name.hasPrefix("codex-") || name.hasPrefix("codex_") {
            return true
        }

        // Prefer filtering by the executable path (proc_pidpath), so we don't match Electron helper processes.
        guard let path = p.path?.lowercased() else { return false }
        let base = URL(fileURLWithPath: path).lastPathComponent.lowercased()

        if base == "codex" || base.hasPrefix("codex-") || base.hasPrefix("codex_") || base.hasPrefix("codex.") {
            return true
        }

        // Codex desktop app bundles ship an internal CLI-like binary at Contents/Resources/codex.
        if path.contains("/codex.app/contents/resources/codex") {
            return true
        }

        return false
    }
}
