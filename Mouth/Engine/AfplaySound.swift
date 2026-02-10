import Foundation

enum AfplaySoundError: Error, LocalizedError {
    case failedToStart(underlying: Error)
    case terminated(status: Int32)

    var errorDescription: String? {
        switch self {
        case let .failedToStart(underlying):
            return "Failed to start afplay: \(underlying)"
        case let .terminated(status):
            return "afplay exited with status \(status)"
        }
    }
}

/// Small wrapper around macOS `/usr/bin/afplay`.
final class AfplaySound {
    final class Playback: @unchecked Sendable {
        let id: UUID

        private let process: Process
        private let terminationTask: Task<Int32, Never>

        fileprivate init(id: UUID, process: Process) {
            self.id = id
            self.process = process

            self.terminationTask = Task {
                await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                    process.terminationHandler = { p in
                        cont.resume(returning: p.terminationStatus)
                    }
                }
            }
        }

        deinit {
            cancel()
        }

        var isRunning: Bool {
            process.isRunning
        }

        func cancel() {
            guard process.isRunning else { return }
            process.terminate()
        }

        func wait() async throws {
            let status = await terminationTask.value
            if status != 0 {
                throw AfplaySoundError.terminated(status: status)
            }
        }
    }

    func play(fileURL: URL, volume: Float? = nil) throws -> Playback {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")

        var args: [String] = []
        if let volume {
            // afplay volume is 0.0 - 1.0
            args += ["-v", String(volume)]
        }
        args.append(fileURL.path)
        process.arguments = args

        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
        } catch {
            throw AfplaySoundError.failedToStart(underlying: error)
        }

        return Playback(id: UUID(), process: process)
    }
}
