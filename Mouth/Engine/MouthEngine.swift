import Foundation

final class MouthEngine {
    private let queue = DispatchQueue(label: "com.zats.Mouth.Engine", qos: .userInitiated)

    private var timer: DispatchSourceTimer?

    var onSessionsChanged: (([CodexActiveSession]) -> Void)?
    var onNewAssistantMessage: ((CodexAssistantMessageEvent) -> Void)?

    private let iso = ISO8601DateFormatter()

    private struct SessionWatch {
        let url: URL
        let sessionID: String?
        let watcher: FileChangeWatcher
        var pids: Set<pid_t>
        var lastChangeAt: Date?
        var fileModificationDate: Date?
        var fileSizeBytes: UInt64?
        var readOffset: UInt64
        var pendingLine: String
        var isPrimed: Bool
        var latestAssistantText: String?
        var latestAssistantAt: Date?
    }

    // PID -> session file path
    private var pidToSessionPath: [pid_t: String] = [:]

    // Session file path -> watcher (deduped)
    private var sessionWatchesByPath: [String: SessionWatch] = [:]

    private var knownCodexPids = Set<pid_t>()
    private var lastNoSessionLogAtByPid: [pid_t: Date] = [:]

    func start() {
        log("start")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.rescan()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        log("stop")
        timer?.cancel()
        timer = nil

        for (_, sw) in sessionWatchesByPath {
            sw.watcher.stop()
        }

        pidToSessionPath.removeAll()
        sessionWatchesByPath.removeAll()
        knownCodexPids.removeAll()
        lastNoSessionLogAtByPid.removeAll()

        emitSessions()
    }

    private func rescan() {
        let snapshot = ProcessSnapshot.capture()

        let codexProcs = snapshot.byPid.values
            .filter { isCodexLikeProcess($0) }

        let currentPids = Set(codexProcs.map(\.pid))

        // Handle exited PIDs.
        let exited = knownCodexPids.subtracting(currentPids)
        if !exited.isEmpty {
            for pid in exited.sorted() {
                handlePidExit(pid: pid)
            }
        }

        // Log newly discovered Codex processes.
        let newPids = currentPids.subtracting(knownCodexPids)
        if !newPids.isEmpty {
            for pid in newPids.sorted() {
                guard let p = snapshot.byPid[pid] else { continue }
                log("codex discovered pid=\(p.pid) ppid=\(p.ppid) name=\(p.name) path=\(p.path ?? "(nil)")")
            }
        }
        knownCodexPids = currentPids

        // Resolve PID -> session mapping and update watchers accordingly.
        for proc in codexProcs {
            do {
                guard let sessionURL = try ProcOpenFiles.findCodexSessionFile(pid: proc.pid) else {
                    maybeLogNoSession(pid: proc.pid)

                    // If a process previously had a session and now doesn't, treat that as a session end.
                    if pidToSessionPath[proc.pid] != nil {
                        updatePid(proc.pid, sessionURL: nil)
                    }
                    continue
                }

                updatePid(proc.pid, sessionURL: sessionURL)
            } catch {
                log("codex pid=\(proc.pid) failed to inspect open files: \(error)")
            }
        }

        // Cleanup any PID mappings that linger for PIDs that are no longer Codex-like.
        // (Should be rare, but prevents leaks if a process changes identity.)
        let mappedPids = Set(pidToSessionPath.keys)
        let staleMapped = mappedPids.subtracting(currentPids)
        if !staleMapped.isEmpty {
            for pid in staleMapped.sorted() {
                handlePidExit(pid: pid)
            }
        }

        // Poll watched files for changes. Some writers don't reliably trigger kqueue file events.
        pollWatchedFiles()

        emitSessions()
    }

    private func updatePid(_ pid: pid_t, sessionURL: URL?) {
        let oldPath = pidToSessionPath[pid]
        let newPath = sessionURL?.path

        if oldPath == newPath {
            return
        }

        if let oldPath {
            removePid(pid, fromSessionPath: oldPath, reason: newPath == nil ? "session ended" : "session switched")
        }

        guard let sessionURL, let newPath else {
            pidToSessionPath[pid] = nil
            return
        }

        pidToSessionPath[pid] = newPath

        let sessionID = ProcOpenFiles.extractSessionID(fromSessionFileURL: sessionURL)
        log("codex session pid=\(pid) id=\(sessionID ?? "(unparsed)")")
        log("codex session pid=\(pid) file=\(newPath)")

        addPid(pid, toSessionURL: sessionURL)
        emitSessions()
    }

    private func addPid(_ pid: pid_t, toSessionURL sessionURL: URL) {
        let path = sessionURL.path

        if var sw = sessionWatchesByPath[path] {
            sw.pids.insert(pid)
            sessionWatchesByPath[path] = sw
            return
        }

        let sessionID = ProcOpenFiles.extractSessionID(fromSessionFileURL: sessionURL)
        let (mtime, err) = fileMTime(path: path)
        if let err {
            log("failed to stat session file: \(path) error=\(err)")
        }
        let (size, sizeErr) = fileSize(path: path)
        if let sizeErr {
            log("failed to size session file: \(path) error=\(sizeErr)")
        }

        let watcher = FileChangeWatcher(url: sessionURL)
        do {
            try watcher.start(queue: queue) { [weak self] event in
                guard let self else { return }

                // We may have multiple PIDs mapped to the same session file.
                let pids = self.sessionWatchesByPath[path]?.pids.sorted() ?? []
                self.log("session changed pids=\(pids) event=\(event) file=\(path)")

                if var sw = self.sessionWatchesByPath[path] {
                    sw.lastChangeAt = Date()
                    let (mtime, _) = self.fileMTime(path: path)
                    sw.fileModificationDate = mtime
                    let (size, _) = self.fileSize(path: path)
                    sw.fileSizeBytes = size
                    self.sessionWatchesByPath[path] = sw
                }

                // Proactively parse on event; some writers don't reliably trigger events.
                self.pollWatchedFiles()
                self.emitSessions()

                // If the file was rotated/renamed/deleted, attempt a quick re-resolve on next tick.
                if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
                    self.invalidateSessionPath(path, reason: "session file rotated")
                }
            }

            let maxInitialScanBytes: UInt64 = 256 * 1024
            let initialOffset: UInt64 = {
                guard let size else { return 0 }
                return size > maxInitialScanBytes ? (size - maxInitialScanBytes) : 0
            }()

	            var sw = SessionWatch(
	                url: sessionURL,
	                sessionID: sessionID,
	                watcher: watcher,
	                pids: [pid],
	                lastChangeAt: nil,
	                fileModificationDate: mtime,
	                fileSizeBytes: size,
	                readOffset: initialOffset,
	                pendingLine: "",
	                isPrimed: false,
	                latestAssistantText: nil,
	                latestAssistantAt: nil
	            )

	            // Initialize latest assistant message by scanning the tail chunk.
	            var newOffset = initialOffset
	            let initialMessages = parseAssistantMessages(
	                path: path,
	                fromOffset: initialOffset,
	                dropFirstPartialLine: initialOffset > 0,
	                pendingLine: &sw.pendingLine,
	                newOffsetOut: &newOffset
	            )
	            if let last = initialMessages.last {
	                sw.latestAssistantText = last.text
	                sw.latestAssistantAt = last.at
	            }
	            sw.readOffset = newOffset
	            sw.isPrimed = true

	            sessionWatchesByPath[path] = sw
        } catch {
            log("failed to watch session file: \(path) error=\(error)")
        }
    }

    private func removePid(_ pid: pid_t, fromSessionPath path: String, reason: String) {
        guard var sw = sessionWatchesByPath[path] else {
            pidToSessionPath[pid] = nil
            return
        }

        sw.pids.remove(pid)
        pidToSessionPath[pid] = nil

        if sw.pids.isEmpty {
            sw.watcher.stop()
            sessionWatchesByPath[path] = nil
            log("stop watching session file=\(path) reason=\(reason)")
        } else {
            sessionWatchesByPath[path] = sw
        }

        emitSessions()
    }

    private func invalidateSessionPath(_ path: String, reason: String) {
        guard let sw = sessionWatchesByPath[path] else { return }

        // Clear PID mappings so the next rescan re-resolves each PID's active session file.
        for pid in sw.pids {
            pidToSessionPath[pid] = nil
        }

        sw.watcher.stop()
        sessionWatchesByPath[path] = nil
        log("invalidated session file=\(path) reason=\(reason)")

        emitSessions()
    }

    private func handlePidExit(pid: pid_t) {
        if let oldPath = pidToSessionPath[pid] {
            removePid(pid, fromSessionPath: oldPath, reason: "process exited")
        } else {
            pidToSessionPath[pid] = nil
        }

        emitSessions()
    }

    private func maybeLogNoSession(pid: pid_t) {
        let now = Date()
        if let last = lastNoSessionLogAtByPid[pid], now.timeIntervalSince(last) < 10 {
            return
        }
        lastNoSessionLogAtByPid[pid] = now
        log("codex pid=\(pid) has no open session file under ~/.codex/sessions")
    }

    private func emitSessions() {
        guard let onSessionsChanged else { return }

        let sessions: [CodexActiveSession] = sessionWatchesByPath
            .values
            .map { sw in
                CodexActiveSession(
                    sessionID: sw.sessionID,
                    fileURL: sw.url,
                    pids: sw.pids.sorted(),
                    lastChangeAt: sw.lastChangeAt,
                    fileModificationDate: sw.fileModificationDate,
                    fileSizeBytes: sw.fileSizeBytes,
                    latestAssistantText: sw.latestAssistantText,
                    latestAssistantAt: sw.latestAssistantAt
                )
            }
            .sorted { lhs, rhs in
                let l = lhs.lastChangeAt ?? lhs.fileModificationDate ?? .distantPast
                let r = rhs.lastChangeAt ?? rhs.fileModificationDate ?? .distantPast
                if l != r { return l > r }
                return lhs.fileURL.path < rhs.fileURL.path
            }

        DispatchQueue.main.async {
            onSessionsChanged(sessions)
        }
    }

    private func pollWatchedFiles() {
        // If mtime or size changes, bump lastChangeAt so UI refreshes.
        let snapshot = sessionWatchesByPath
        for (path, var sw) in snapshot {
            let (mtime, _) = fileMTime(path: path)
            let (size, _) = fileSize(path: path)

            let mtimeChanged = mtime != nil && mtime != sw.fileModificationDate
            let sizeChanged = size != nil && size != sw.fileSizeBytes

	            if let size, size < sw.readOffset {
	                // File was truncated/rotated; start over.
	                sw.readOffset = 0
	                sw.pendingLine = ""
	            }

	            if let size, size > sw.readOffset {
	                var newOffset = sw.readOffset
	                let messages = parseAssistantMessages(
	                    path: path,
	                    fromOffset: sw.readOffset,
	                    dropFirstPartialLine: sw.readOffset > 0 && sw.pendingLine.isEmpty,
	                    pendingLine: &sw.pendingLine,
	                    newOffsetOut: &newOffset
	                )

	                if !messages.isEmpty {
	                    for m in messages {
	                        let isNew: Bool
	                        if let newAt = m.at, let oldAt = sw.latestAssistantAt {
	                            isNew = newAt > oldAt
	                        } else if sw.latestAssistantAt == nil {
	                            isNew = true
	                        } else {
	                            // If we have no timestamp, treat it as new but avoid repeating identical text.
	                            isNew = sw.latestAssistantText != m.text
	                        }

	                        if sw.isPrimed, isNew {
	                            let event = CodexAssistantMessageEvent(
	                                sessionID: sw.sessionID,
	                                sessionFileURL: sw.url,
	                                text: m.text,
	                                timestamp: m.at
	                            )
	                            DispatchQueue.main.async { [weak self] in
	                                self?.onNewAssistantMessage?(event)
	                            }
	                        }

	                        sw.latestAssistantText = m.text
	                        if let at = m.at {
	                            sw.latestAssistantAt = at
	                        }
	                    }
	                }
	                sw.readOffset = newOffset
	            }

            if mtimeChanged || sizeChanged {
                sw.fileModificationDate = mtime ?? sw.fileModificationDate
                sw.fileSizeBytes = size ?? sw.fileSizeBytes
                sw.lastChangeAt = Date()
                sessionWatchesByPath[path] = sw
            } else {
                // Keep the updated readOffset/latestAssistant even if metadata didn't change.
                sessionWatchesByPath[path] = sw
            }
        }
    }

    private struct AssistantMessage {
        let text: String
        let at: Date?
    }

    private func parseAssistantMessages(
        path: String,
        fromOffset offset: UInt64,
        dropFirstPartialLine: Bool,
        pendingLine: inout String,
        newOffsetOut: inout UInt64
    ) -> [AssistantMessage] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }

        do {
            try fh.seek(toOffset: offset)
            let data = try fh.readToEnd() ?? Data()
            newOffsetOut = offset + UInt64(data.count)
            if data.isEmpty { return [] }

            var combined = pendingLine + String(decoding: data, as: UTF8.self)
            pendingLine = ""

            if dropFirstPartialLine, let idx = combined.firstIndex(of: "\n") {
                combined = String(combined[combined.index(after: idx)...])
            }

            var lines = combined.split(separator: "\n", omittingEmptySubsequences: true)
            if !combined.hasSuffix("\n"), let last = lines.last {
                pendingLine = String(last)
                lines.removeLast()
            }

            if lines.isEmpty { return [] }

            var out: [AssistantMessage] = []
            out.reserveCapacity(4)

            for lineSub in lines {
                guard let lineData = String(lineSub).data(using: .utf8) else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: lineData),
                      let dict = obj as? [String: Any]
                else { continue }

                guard (dict["type"] as? String) == "response_item" else { continue }
                guard let payload = dict["payload"] as? [String: Any] else { continue }
                guard (payload["type"] as? String) == "message" else { continue }
                guard (payload["role"] as? String) == "assistant" else { continue }

                guard let content = payload["content"] as? [[String: Any]] else { continue }
                let texts = content.compactMap { item -> String? in
                    guard (item["type"] as? String) == "output_text" else { return nil }
                    return item["text"] as? String
                }
                let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if joined.isEmpty { continue }

                let at: Date?
                if let ts = dict["timestamp"] as? String {
                    at = iso.date(from: ts)
                } else {
                    at = nil
                }

                out.append(AssistantMessage(text: joined, at: at))
            }

            return out
        } catch {
            return []
        }
    }

    private func fileMTime(path: String) -> (Date?, String?) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return (attrs[.modificationDate] as? Date, nil)
        } catch {
            return (nil, String(describing: error))
        }
    }

    private func fileSize(path: String) -> (UInt64?, String?) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return (attrs[.size] as? UInt64, nil)
        } catch {
            return (nil, String(describing: error))
        }
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

    private func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[MouthEngine \(ts)] \(msg)")
    }
}
