import Foundation
import Darwin

struct ProcessSnapshot {
    struct ProcessInfo {
        let pid: pid_t
        let ppid: pid_t
        let name: String
        let path: String?
    }

    let byPid: [pid_t: ProcessInfo]

    static func capture() -> ProcessSnapshot {
        let count = proc_listallpids(nil, 0)
        if count <= 0 {
            return ProcessSnapshot(byPid: [:])
        }

        var pids = Array<pid_t>(repeating: 0, count: Int(count))
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let filled = proc_listallpids(&pids, bytes)
        if filled <= 0 {
            return ProcessSnapshot(byPid: [:])
        }

        pids = pids.prefix(Int(filled)).filter { $0 > 0 }

        var map: [pid_t: ProcessInfo] = [:]
        map.reserveCapacity(pids.count)

        for pid in pids {
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
            if ret != infoSize {
                continue
            }

            let name = withUnsafePointer(to: &info.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { ptr in
                    String(cString: ptr)
                }
            }

            let path = ProcessSnapshot.pidPath(pid)

            map[pid] = ProcessInfo(pid: pid, ppid: pid_t(info.pbi_ppid), name: name, path: path)
        }

        return ProcessSnapshot(byPid: map)
    }

    func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        if pid == ancestor { return true }

        var cursor = pid
        var visited = Set<pid_t>()

        while cursor > 1 {
            if cursor == ancestor { return true }
            if visited.contains(cursor) { return false }
            visited.insert(cursor)

            guard let p = byPid[cursor] else { return false }
            cursor = p.ppid
        }

        return false
    }

    private static func pidPath(_ pid: pid_t) -> String? {
        var buf = Array<CChar>(repeating: 0, count: Int(MAXPATHLEN))
        let ret = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard ret > 0 else { return nil }
        return String(cString: buf)
    }
}
