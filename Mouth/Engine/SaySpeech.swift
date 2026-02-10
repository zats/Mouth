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
        private var lifetimeWriteHandle: FileHandle?
        private var terminationTask: Task<Int32, Never>?

        fileprivate init(id: UUID, process: Process, lifetimeWriteHandle: FileHandle?) {
            self.id = id
            self.process = process
            self.lifetimeWriteHandle = lifetimeWriteHandle

            let task = Task {
                await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                    process.terminationHandler = { [weak self] p in
                        self?.closeLifetimeHandle()
                        cont.resume(returning: p.terminationStatus)
                    }
                }
            }
            terminationTask = task
        }

        deinit {
            cancel()
        }

        var isRunning: Bool {
            process.isRunning
        }

        func cancel() {
            closeLifetimeHandle()
            guard process.isRunning else { return }
            process.terminate()
        }

        /// Waits for `/usr/bin/say` to exit.
        func wait() async throws {
            guard let terminationTask else { return }
            let status = await terminationTask.value
            if status != 0 {
                throw SaySpeechError.terminated(status: status)
            }
        }

        private func closeLifetimeHandle() {
            // Closing this handle causes the wrapper to observe EOF and terminate `say`.
            if let h = lifetimeWriteHandle {
                try? h.close()
                lifetimeWriteHandle = nil
            }
        }
    }

    func play(
        _ text: String,
        voice: String? = nil,
        rate: Int? = nil
    ) throws -> Playback {
        // We run `say` through a small watchdog wrapper so that if this app crashes/exits,
        // the wrapper observes EOF on stdin (a pipe held open by this app) and terminates `say`.
        //
        // This is the closest thing to a "kill child on parent death" behavior on macOS
        // without relying on private APIs or a persistent helper daemon.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")

        let lifetimePipe = Pipe()
        process.standardInput = lifetimePipe

        guard let textData = text.data(using: .utf8) else {
            throw SaySpeechError.textEncodingFailed
        }
        let textB64 = textData.base64EncodedString()

        let script = Self.sayWrapperPython

        var args: [String] = ["-c", script, "--"]
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
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
        } catch {
            throw SaySpeechError.failedToStart(underlying: error)
        }

        return Playback(id: UUID(), process: process, lifetimeWriteHandle: lifetimePipe.fileHandleForWriting)
    }

    // Python wrapper arguments (after "--"):
    // 1) voice (or ""), 2) rate (or ""), 3) text_b64
    private static let sayWrapperPython = #"""
import base64
import os
import select
import signal
import subprocess
import sys
import time

def main() -> int:
    args = sys.argv
    if "--" in args:
        idx = args.index("--")
        args = args[idx+1:]
    else:
        args = args[1:]

    if len(args) != 3:
        return 2

    voice = args[0]
    rate = args[1]
    text_b64 = args[2]

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

    # stdin is inherited from this wrapper (a pipe owned by the parent app). We set say's stdin
    # to DEVNULL to ensure it doesn't accidentally interact with our lifetime pipe.
    p = subprocess.Popen(say_args, stdin=subprocess.DEVNULL)

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

        # If the parent app exits/crashes, our stdin pipe will close and become readable with EOF.
        try:
            r, _, _ = select.select([sys.stdin], [], [], 0)
            if r:
                b = os.read(sys.stdin.fileno(), 1)
                if b == b"":
                    try:
                        p.terminate()
                    except Exception:
                        pass
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
        except Exception:
            # If we can't read stdin for any reason, fall back to not force-stopping.
            pass

        time.sleep(0.1)

if __name__ == "__main__":
    sys.exit(main())
"""#
}
