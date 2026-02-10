import AppKit
import Foundation

final class MouthEngine {
    private let queue = DispatchQueue(label: "com.zats.Mouth.Engine", qos: .userInitiated)

    private var timer: DispatchSourceTimer?
    private var lastFrontmostPid: pid_t?

    // Keyed by Codex PID.
    private var watchers: [pid_t: FileChangeWatcher] = [:]
    private var watchedSessionPathByPid: [pid_t: String] = [:]

    func start() {
        log("start")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.tick()
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
    }

    private func tick() {
        autoreleasepool {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let frontmostPid = frontmost?.processIdentifier

            if frontmostPid != lastFrontmostPid {
                lastFrontmostPid = frontmostPid

                let bundleID = frontmost?.bundleIdentifier ?? "(nil)"
                let name = frontmost?.localizedName ?? "(nil)"
                log("frontmost: \(name) pid=\(frontmostPid.map(String.init) ?? "nil") bundle=\(bundleID)")
            }

            guard let frontmostPid else {
                rescan(frontmostPid: nil)
                return
            }

            rescan(frontmostPid: frontmostPid)
        }
    }

    private func rescan(frontmostPid: pid_t?) {
        let snapshot = ProcessSnapshot.capture()

        let codexProcs = snapshot.byPid.values
            .filter { isCodexLikeProcess($0) }

        if codexProcs.isEmpty {
            stopWatchingAll()
            return
        }

        var visibleCodexPids = Set<pid_t>()
        if let frontmostPid {
            for p in codexProcs {
                if snapshot.isDescendant(p.pid, of: frontmostPid) {
                    visibleCodexPids.insert(p.pid)
                }
            }
        }

        // If Codex itself is frontmost, treat it as visible too.
        if let frontmostPid, codexProcs.contains(where: { $0.pid == frontmostPid }) {
            visibleCodexPids.insert(frontmostPid)
        }

        // Stop watchers for Codex processes that are no longer visible.
        for (pid, _) in watchers {
            if !visibleCodexPids.contains(pid) {
                stopWatching(pid: pid)
            }
        }

        // Start/refresh watchers for visible Codex processes.
        for proc in codexProcs where visibleCodexPids.contains(proc.pid) {
            do {
                guard let sessionURL = try ProcOpenFiles.findCodexSessionFile(pid: proc.pid) else {
                    log("codex pid=\(proc.pid) visible=yes but no session file found in open fds")
                    continue
                }

                let sessionPath = sessionURL.path
                if watchedSessionPathByPid[proc.pid] == sessionPath {
                    continue
                }

                let sessionID = sessionURL.deletingPathExtension().lastPathComponent

                log("codex visible pid=\(proc.pid) ppid=\(proc.ppid) name=\(proc.name) path=\(proc.path ?? "(nil)")")
                log("codex session pid=\(proc.pid) id=\(sessionID)")
                log("codex session pid=\(proc.pid) file=\(sessionPath)")

                startWatching(pid: proc.pid, sessionURL: sessionURL)
            } catch {
                log("codex pid=\(proc.pid) failed to inspect open files: \(error)")
            }
        }

        if visibleCodexPids.isEmpty {
            stopWatchingAll()
        }
    }

    private func startWatching(pid: pid_t, sessionURL: URL) {
        stopWatching(pid: pid)

        let watcher = FileChangeWatcher(url: sessionURL)
        do {
            try watcher.start(queue: queue) { [weak self] event in
                self?.log("session changed pid=\(pid) event=\(event) file=\(sessionURL.path)")

                // If the file was rotated/renamed/deleted, attempt a quick re-resolve on next tick.
                if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
                    self?.watchedSessionPathByPid[pid] = nil
                }
            }
            watchers[pid] = watcher
            watchedSessionPathByPid[pid] = sessionURL.path
        } catch {
            log("failed to watch session file for pid=\(pid): \(error)")
        }
    }

    private func stopWatching(pid: pid_t) {
        watchers[pid]?.stop()
        watchers[pid] = nil
        watchedSessionPathByPid[pid] = nil
        log("stop watching pid=\(pid)")
    }

    private func stopWatchingAll() {
        if watchers.isEmpty { return }
        for (pid, _) in watchers {
            stopWatching(pid: pid)
        }
    }

    private func isCodexLikeProcess(_ p: ProcessSnapshot.ProcessInfo) -> Bool {
        let name = p.name.lowercased()
        if name == "codex" || name.hasPrefix("codex-") || name.hasPrefix("codex_") {
            return true
        }

        if name == "codex" || name == "codexbar" {
            return true
        }

        if let path = p.path?.lowercased() {
            let base = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if base == "codex" || base.hasPrefix("codex-") || base.contains("codex") {
                // Avoid Electron helper processes like "Codex Helper" which don't have a codex executable basename.
                if base.contains("helper") { return false }
                return true
            }
        }

        return false
    }

    private func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[MouthEngine \(ts)] \(msg)")
    }
}
