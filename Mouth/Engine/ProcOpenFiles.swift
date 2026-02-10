import Foundation
import Darwin

enum ProcOpenFiles {
    struct OpenFile {
        let fd: Int32
        let path: String
    }

    static func listOpenFiles(pid: pid_t) throws -> [OpenFile] {
        // First call to get needed buffer size.
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if needed <= 0 {
            throw posixError("proc_pidinfo(PROC_PIDLISTFDS)")
        }

        let fdCount = Int(needed) / MemoryLayout<proc_fdinfo>.stride
        var fdInfos = Array<proc_fdinfo>(repeating: proc_fdinfo(), count: fdCount)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdInfos, Int32(fdInfos.count * MemoryLayout<proc_fdinfo>.stride))
        if filled <= 0 {
            throw posixError("proc_pidinfo(PROC_PIDLISTFDS, filled)")
        }

        let actualCount = Int(filled) / MemoryLayout<proc_fdinfo>.stride
        if actualCount <= 0 {
            return []
        }

        var out: [OpenFile] = []
        out.reserveCapacity(actualCount)

        for i in 0..<actualCount {
            let fdInfo = fdInfos[i]
            guard fdInfo.proc_fdtype == PROX_FDTYPE_VNODE else { continue }

            var vnodeInfo = vnode_fdinfowithpath()
            let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            let ret = proc_pidfdinfo(pid, fdInfo.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnodeInfo, vnodeSize)
            if ret != vnodeSize {
                continue
            }

            let path = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { ptr in
                    String(cString: ptr)
                }
            }

            if path.isEmpty { continue }
            out.append(OpenFile(fd: fdInfo.proc_fd, path: path))
        }

        return out
    }

    static func findCodexSessionFile(pid: pid_t) throws -> URL? {
        let openFiles = try listOpenFiles(pid: pid)

        // Prefer session jsonl files (Codex keeps a per-session rollout log under ~/.codex/sessions/...)
        let candidates: [String] = openFiles
            .map { $0.path }
            .filter { $0.contains("/.codex/sessions/") }
            .filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".json") }

        if candidates.isEmpty {
            return nil
        }

        let rollout = candidates.filter { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("rollout-") }
        let pool = rollout.isEmpty ? candidates : rollout

        // Prefer the most recently modified file.
        let fm = FileManager.default
        let best = pool.max { lhs, rhs in
            let lmt = (try? fm.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
            let rmt = (try? fm.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
            return lmt < rmt
        }

        guard let best else { return nil }
        return URL(fileURLWithPath: best)
    }

    static func extractSessionID(fromSessionFileURL url: URL) -> String? {
        // Example filename:
        // rollout-2026-02-10T09-22-00-019c47ee-3a99-7502-96f3-7543c08076d6.jsonl
        let base = url.deletingPathExtension().lastPathComponent

        // Match a UUID-looking suffix (Codex session ids are typically UUID-ish).
        let pattern = #"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(base.startIndex..<base.endIndex, in: base)
        guard let m = re.firstMatch(in: base, range: range), m.numberOfRanges >= 2 else { return nil }
        guard let r = Range(m.range(at: 1), in: base) else { return nil }
        return String(base[r])
    }

    private static func posixError(_ what: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
