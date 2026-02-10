import Foundation

enum SaySpeechError: Error, LocalizedError {
    case failedToStart(underlying: Error)
    case terminated(status: Int32)

    var errorDescription: String? {
        switch self {
        case let .failedToStart(underlying):
            return "Failed to start say: \(underlying)"
        case let .terminated(status):
            return "say exited with status \(status)"
        }
    }
}

/// Small wrapper around macOS `/usr/bin/say`.
///
/// Usage:
/// ```swift
/// let speaker = SaySpeech()
/// let playback = try speaker.play("Hello")
/// // ... later
/// try await playback.wait()
/// // or cancel
/// playback.cancel()
/// ```
final class SaySpeech {
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

        /// Waits for `/usr/bin/say` to exit.
        func wait() async throws {
            let status = await terminationTask.value
            if status != 0 {
                throw SaySpeechError.terminated(status: status)
            }
        }
    }

    func play(
        _ text: String,
        voice: String? = nil,
        rate: Int? = nil
    ) throws -> Playback {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")

        var args: [String] = []
        if let voice, !voice.isEmpty {
            args += ["-v", voice]
        }
        if let rate {
            args += ["-r", String(rate)]
        }
        args.append(text)
        process.arguments = args

        // Avoid inheriting unexpected stdio state.
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
        } catch {
            throw SaySpeechError.failedToStart(underlying: error)
        }

        return Playback(id: UUID(), process: process)
    }
}
