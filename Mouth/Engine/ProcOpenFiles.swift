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
        let candidates = openFiles
            .map { $0.path }
            .filter { $0.contains("/.codex/sessions/") }
            .filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".json") }

        guard let best = candidates.sorted(by: { $0.count < $1.count }).first else {
            return nil
        }

        return URL(fileURLWithPath: best)
    }

    private static func posixError(_ what: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
