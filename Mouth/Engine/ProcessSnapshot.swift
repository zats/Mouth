import Foundation
import Darwin

struct ProcessSnapshot {
    struct CaptureDiagnostics {
        let listAllPidsInitial: Int32
        let listAllPidsFilled: Int32
        let pidInfoOK: Int
        let pidInfoFailed: Int
        let pidPathFailed: Int

        // errno is process-global; we capture it right after the syscall-like calls for hinting.
        let errnoAfterInitial: Int32
        let errnoAfterFilled: Int32

        var summary: String {
            "pidsInitial=\(listAllPidsInitial) errnoInitial=\(errnoAfterInitial) pidsFilled=\(listAllPidsFilled) errnoFilled=\(errnoAfterFilled) pidInfoOK=\(pidInfoOK) pidInfoFailed=\(pidInfoFailed) pidPathFailed=\(pidPathFailed)"
        }
    }

    struct ProcessInfo {
        let pid: pid_t
        let ppid: pid_t
        let name: String
        let path: String?
    }

    let byPid: [pid_t: ProcessInfo]

    static func capture() -> ProcessSnapshot {
        captureWithDiagnostics().snapshot
    }

    static func captureWithDiagnostics() -> (snapshot: ProcessSnapshot, diagnostics: CaptureDiagnostics) {
        errno = 0
        let initial = proc_listallpids(nil, 0)
        let errnoAfterInitial = errno

        if initial <= 0 {
            let diag = CaptureDiagnostics(
                listAllPidsInitial: initial,
                listAllPidsFilled: 0,
                pidInfoOK: 0,
                pidInfoFailed: 0,
                pidPathFailed: 0,
                errnoAfterInitial: errnoAfterInitial,
                errnoAfterFilled: 0
            )
            return (ProcessSnapshot(byPid: [:]), diag)
        }

        var pids = Array<pid_t>(repeating: 0, count: Int(initial))
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        errno = 0
        let filled = proc_listallpids(&pids, bytes)
        let errnoAfterFilled = errno

        if filled <= 0 {
            let diag = CaptureDiagnostics(
                listAllPidsInitial: initial,
                listAllPidsFilled: filled,
                pidInfoOK: 0,
                pidInfoFailed: 0,
                pidPathFailed: 0,
                errnoAfterInitial: errnoAfterInitial,
                errnoAfterFilled: errnoAfterFilled
            )
            return (ProcessSnapshot(byPid: [:]), diag)
        }

        pids = pids.prefix(Int(filled)).filter { $0 > 0 }

        var map: [pid_t: ProcessInfo] = [:]
        map.reserveCapacity(pids.count)

        var pidInfoOK = 0
        var pidInfoFailed = 0
        var pidPathFailed = 0

        for pid in pids {
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
            if ret != infoSize {
                pidInfoFailed += 1
                continue
            }
            pidInfoOK += 1

            let name = withUnsafePointer(to: &info.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { ptr in
                    String(cString: ptr)
                }
            }

            let path = ProcessSnapshot.pidPath(pid)
            if path == nil { pidPathFailed += 1 }

            map[pid] = ProcessInfo(pid: pid, ppid: pid_t(info.pbi_ppid), name: name, path: path)
        }

        let diag = CaptureDiagnostics(
            listAllPidsInitial: initial,
            listAllPidsFilled: filled,
            pidInfoOK: pidInfoOK,
            pidInfoFailed: pidInfoFailed,
            pidPathFailed: pidPathFailed,
            errnoAfterInitial: errnoAfterInitial,
            errnoAfterFilled: errnoAfterFilled
        )

        return (ProcessSnapshot(byPid: map), diag)
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
