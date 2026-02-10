import Foundation

final class MouthEngine {
    private let queue = DispatchQueue(label: "com.zats.Mouth.Engine", qos: .userInitiated)

    private var timer: DispatchSourceTimer?

    var onNewAssistantMessage: ((AssistantMessageEvent) -> Void)?

    private let iso = ISO8601DateFormatter()
    private var paused = false

    private let providersBySource: [MouthSessionSource: MouthSessionProvider]

    private struct SessionKey: Hashable {
        let source: MouthSessionSource
        let path: String
    }

    private struct SessionWatch {
        var descriptor: MouthDiscoveredSession
        let watcher: FileChangeWatcher
        var fileModificationDate: Date?
        var fileSizeBytes: UInt64?
        var readOffset: UInt64
        var pendingLine: String
        var isPrimed: Bool
        var latestAssistantText: String?
        var latestAssistantAt: Date?
    }

    private var watches: [SessionKey: SessionWatch] = [:]

    init(providers: [MouthSessionProvider]? = nil) {
        let logger: (String) -> Void = { msg in
            #if DEBUG
            let ts = ISO8601DateFormatter().string(from: Date())
            print("[MouthEngine \(ts)] \(msg)")
            #endif
        }

        let resolved = providers ?? [
            CodexSessionProvider(logger: logger),
            ClaudeCodeSessionProvider(logger: logger)
        ]

        var map: [MouthSessionSource: MouthSessionProvider] = [:]
        for p in resolved {
            map[p.source] = p
        }
        providersBySource = map
    }

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

        for (_, sw) in watches {
            sw.watcher.stop()
        }

        watches.removeAll()
    }

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.paused == paused { return }
            self.paused = paused

            if !paused {
                // On resume, fast-forward session offsets so we don't emit/speak backlog.
                self.primeAllWatches()
            }
        }
    }

    private func rescan() {
        if paused {
            return
        }

        var discoveredByKey: [SessionKey: MouthDiscoveredSession] = [:]

        for provider in providersBySource.values {
            let sessions = provider.discoverSessions()
            for s in sessions {
                let key = SessionKey(source: s.source, path: s.fileURL.path)
                if var existing = discoveredByKey[key] {
                    existing = MouthDiscoveredSession(
                        source: existing.source,
                        sessionID: existing.sessionID ?? s.sessionID,
                        fileURL: existing.fileURL,
                        owners: existing.owners.union(s.owners)
                    )
                    discoveredByKey[key] = existing
                } else {
                    discoveredByKey[key] = s
                }
            }
        }

        // Stop watches that are no longer discovered.
        let removedKeys = Set(watches.keys).subtracting(discoveredByKey.keys)
        if !removedKeys.isEmpty {
            for key in removedKeys {
                if let sw = watches[key] {
                    sw.watcher.stop()
                    log("stop watching source=\(key.source.rawValue) file=\(key.path)")
                }
                watches[key] = nil
            }
        }

        // Add or update watches.
        for (key, desc) in discoveredByKey {
            if var sw = watches[key] {
                sw.descriptor = desc
                watches[key] = sw
            } else {
                addWatch(key: key, descriptor: desc)
            }
        }

        // Some writers don't reliably trigger kqueue file events, so we also poll.
        pollWatchedFiles()
    }

    private func addWatch(key: SessionKey, descriptor: MouthDiscoveredSession) {
        let path = descriptor.fileURL.path

        let (mtime, err) = fileMTime(path: path)
        if let err {
            log("failed to stat session file: \(path) error=\(err)")
        }
        let (size, sizeErr) = fileSize(path: path)
        if let sizeErr {
            log("failed to size session file: \(path) error=\(sizeErr)")
        }

        let watcher = FileChangeWatcher(url: descriptor.fileURL)
        do {
            try watcher.start(queue: queue) { [weak self] event in
                guard let self else { return }
                if self.paused { return }

                // Proactively parse on event; some writers don't reliably trigger events.
                self.pollWatchedFiles()

                // If the file was rotated/renamed/deleted, drop the watch.
                if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
                    self.invalidateWatch(key: key, reason: "session file rotated")
                }
            }

            let maxInitialScanBytes: UInt64 = 256 * 1024
            let initialOffset: UInt64 = {
                guard let size else { return 0 }
                return size > maxInitialScanBytes ? (size - maxInitialScanBytes) : 0
            }()

            var sw = SessionWatch(
                descriptor: descriptor,
                watcher: watcher,
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
                source: descriptor.source,
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

            watches[key] = sw
            log("watching source=\(descriptor.source.rawValue) file=\(path)")
        } catch {
            log("failed to watch session file: \(path) error=\(error)")
        }
    }

    private func invalidateWatch(key: SessionKey, reason: String) {
        guard let sw = watches[key] else { return }
        sw.watcher.stop()
        watches[key] = nil
        log("invalidated source=\(key.source.rawValue) file=\(key.path) reason=\(reason)")
    }

    private func pollWatchedFiles() {
        if paused {
            return
        }

        let snapshot = watches
        for (key, var sw) in snapshot {
            let path = sw.descriptor.fileURL.path

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
                    source: key.source,
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
                            let event = AssistantMessageEvent(
                                source: key.source,
                                sessionID: sw.descriptor.sessionID,
                                sessionFileURL: sw.descriptor.fileURL,
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
                watches[key] = sw
            } else {
                // Keep updated readOffset/latestAssistant even if metadata didn't change.
                watches[key] = sw
            }
        }
    }

    private func primeAllWatches() {
        let snapshot = watches
        for (key, var sw) in snapshot {
            let path = sw.descriptor.fileURL.path

            let (size, _) = fileSize(path: path)
            let maxInitialScanBytes: UInt64 = 256 * 1024
            let initialOffset: UInt64 = {
                guard let size else { return 0 }
                return size > maxInitialScanBytes ? (size - maxInitialScanBytes) : 0
            }()

            sw.readOffset = initialOffset
            sw.pendingLine = ""
            sw.isPrimed = false

            var newOffset = initialOffset
            let messages = parseAssistantMessages(
                source: key.source,
                path: path,
                fromOffset: initialOffset,
                dropFirstPartialLine: initialOffset > 0,
                pendingLine: &sw.pendingLine,
                newOffsetOut: &newOffset
            )
            if let last = messages.last {
                sw.latestAssistantText = last.text
                sw.latestAssistantAt = last.at
            }
            sw.readOffset = newOffset
            sw.fileSizeBytes = size ?? sw.fileSizeBytes
            sw.isPrimed = true

            watches[key] = sw
        }
    }

    private func parseAssistantMessages(
        source: MouthSessionSource,
        path: String,
        fromOffset offset: UInt64,
        dropFirstPartialLine: Bool,
        pendingLine: inout String,
        newOffsetOut: inout UInt64
    ) -> [MouthAssistantMessage] {
        guard let provider = providersBySource[source] else { return [] }
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

            var out: [MouthAssistantMessage] = []
            out.reserveCapacity(4)

            for lineSub in lines {
                guard let lineData = String(lineSub).data(using: .utf8) else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: lineData),
                      let dict = obj as? [String: Any]
                else { continue }

                if let m = provider.parseAssistantMessage(dict: dict, iso: iso) {
                    out.append(m)
                }
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

    private func log(_ msg: String) {
        #if DEBUG
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[MouthEngine \(ts)] \(msg)")
        #endif
    }
}
