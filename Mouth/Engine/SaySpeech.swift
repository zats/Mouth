import Foundation

enum SaySpeechError: Error, LocalizedError {
    case failedToStart(underlying: Error)
    case terminated(status: Int32)
    case textEncodingFailed

    var errorDescription: String? {
        switch self {
        case let .failedToStart(underlying):
            return "Failed to start say: \(underlying)"
        case let .terminated(status):
            return "say exited with status \(status)"
        case .textEncodingFailed:
            return "Failed to encode text for say wrapper"
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
        // We run `say` through a small watchdog wrapper so that if this app crashes/exits,
        // the wrapper notices the parent PID is gone and terminates `say`.
        //
        // This is the closest thing to a "kill child on parent death" behavior on macOS
        // without relying on private APIs or a persistent helper daemon.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")

        guard let textData = text.data(using: .utf8) else {
            throw SaySpeechError.textEncodingFailed
        }
        let textB64 = textData.base64EncodedString()

        let script = Self.sayWrapperPython

        var args: [String] = ["-c", script, "--"]
        args.append(String(getpid())) // parent PID to monitor
        if let voice, !voice.isEmpty {
            args.append(voice)
        } else {
            args.append("")
        }
        if let rate {
            args.append(String(rate))
        } else {
            args.append("")
        }
        args.append(textB64)
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

    // Python wrapper arguments (after "--"):
    // 1) parent_pid, 2) voice (or ""), 3) rate (or ""), 4) text_b64
    private static let sayWrapperPython = #"""
import base64
import os
import signal
import subprocess
import sys
import time

def parent_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def main() -> int:
    args = sys.argv
    if "--" in args:
        idx = args.index("--")
        args = args[idx+1:]
    else:
        args = args[1:]

    if len(args) != 4:
        return 2

    parent_pid = int(args[0])
    voice = args[1]
    rate = args[2]
    text_b64 = args[3]

    try:
        text = base64.b64decode(text_b64.encode("ascii")).decode("utf-8", errors="replace")
    except Exception:
        return 3

    say_args = ["/usr/bin/say"]
    if voice:
        say_args += ["-v", voice]
    if rate:
        say_args += ["-r", rate]
    say_args.append(text)

    p = subprocess.Popen(say_args)

    def handle_term(signum, frame):
        try:
            p.terminate()
        except Exception:
            pass

    signal.signal(signal.SIGTERM, handle_term)
    signal.signal(signal.SIGINT, handle_term)

    while True:
        rc = p.poll()
        if rc is not None:
            return int(rc)

        if not parent_alive(parent_pid):
            try:
                p.terminate()
            except Exception:
                pass
            # Give it a moment to exit, then force kill.
            for _ in range(10):
                rc = p.poll()
                if rc is not None:
                    return int(rc)
                time.sleep(0.05)
            try:
                p.kill()
            except Exception:
                pass
            return 0

        time.sleep(0.1)

if __name__ == "__main__":
    sys.exit(main())
"""#
}
