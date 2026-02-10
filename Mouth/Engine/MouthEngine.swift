import Foundation

final class MouthEngine {
    private let queue = DispatchQueue(label: "com.zats.Mouth.Engine", qos: .userInitiated)

    private var timer: DispatchSourceTimer?

    // Keyed by Codex PID.
    private var watchers: [pid_t: FileChangeWatcher] = [:]
    private var watchedSessionPathByPid: [pid_t: String] = [:]
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

        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
        watchedSessionPathByPid.removeAll()
        knownCodexPids.removeAll()
        lastNoSessionLogAtByPid.removeAll()
    }

    private func rescan() {
        let snapshot = ProcessSnapshot.capture()

        let codexProcs = snapshot.byPid.values
            .filter { isCodexLikeProcess($0) }

        let currentPids = Set(codexProcs.map(\.pid))

        // Stop watchers for Codex processes that have exited.
        for (pid, _) in watchers where !currentPids.contains(pid) {
            stopWatching(pid: pid, reason: "process exited")
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

        // Start/refresh watchers for any Codex process that appears to have a session file open.
        for proc in codexProcs {
            do {
                guard let sessionURL = try ProcOpenFiles.findCodexSessionFile(pid: proc.pid) else {
                    maybeLogNoSession(pid: proc.pid)
                    continue
                }

                let sessionPath = sessionURL.path
                if watchedSessionPathByPid[proc.pid] == sessionPath {
                    continue
                }

                let sessionID = ProcOpenFiles.extractSessionID(fromSessionFileURL: sessionURL)

                log("codex session pid=\(proc.pid) id=\(sessionID ?? "(unparsed)")")
                log("codex session pid=\(proc.pid) file=\(sessionPath)")

                startWatching(pid: proc.pid, sessionURL: sessionURL)
            } catch {
                log("codex pid=\(proc.pid) failed to inspect open files: \(error)")
            }
        }
    }

    private func startWatching(pid: pid_t, sessionURL: URL) {
        stopWatching(pid: pid, reason: "replacing watcher")

        let watcher = FileChangeWatcher(url: sessionURL)
        do {
            try watcher.start(queue: queue) { [weak self] event in
                self?.log("session changed pid=\(pid) event=\(event) file=\(sessionURL.path)")

                // If the file was rotated/renamed/deleted, attempt a quick re-resolve on next tick.
                if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
                    self?.stopWatching(pid: pid, reason: "session file rotated")
                }
            }
            watchers[pid] = watcher
            watchedSessionPathByPid[pid] = sessionURL.path
        } catch {
            log("failed to watch session file for pid=\(pid): \(error)")
        }
    }

    private func stopWatching(pid: pid_t, reason: String) {
        guard watchers[pid] != nil else { return }
        watchers[pid]?.stop()
        watchers[pid] = nil
        watchedSessionPathByPid[pid] = nil
        log("stop watching pid=\(pid) reason=\(reason)")
    }

    private func maybeLogNoSession(pid: pid_t) {
        let now = Date()
        if let last = lastNoSessionLogAtByPid[pid], now.timeIntervalSince(last) < 10 {
            return
        }
        lastNoSessionLogAtByPid[pid] = now
        log("codex pid=\(pid) has no open session file under ~/.codex/sessions")
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
