import Foundation
import Security

enum SaySpeechError: Error, LocalizedError {
    case failedToStart(underlying: Error)
    case terminated(status: Int32)
    case textEncodingFailed

    var errorDescription: String? {
        switch self {
        case let .failedToStart(underlying):
            return "Failed to start speech command: \(underlying)"
        case let .terminated(status):
            return "Speech command exited with status \(status)"
        case .textEncodingFailed:
            return "Failed to encode text for speech wrapper"
        }
    }
}

/// Wrapper around either macOS `/usr/bin/say` or `sag` (if installed and selected).
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
    enum Provider: String, CaseIterable, Identifiable {
        case macOSSay = "macos_say"
        case sag = "sag"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .macOSSay:
                return "say - default"
            case .sag:
                return "sag - ElevenLabs"
            }
        }
    }

    static let providerDefaultsKey = "mouth.speech.provider"

    static func preferredProvider() -> Provider {
        let raw = UserDefaults.standard.string(forKey: providerDefaultsKey)
        return Provider(rawValue: raw ?? "") ?? .macOSSay
    }

    static func setPreferredProvider(_ provider: Provider) {
        UserDefaults.standard.set(provider.rawValue, forKey: providerDefaultsKey)
    }

    static func isSAGInstalled() -> Bool {
        sagExecutableURL() != nil
    }

    static func hasSAGAPIKey() -> Bool {
        (try? loadSAGAPIKey()) != nil
    }

    static func setSAGAPIKey(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try upsertKeychainString(
            (trimmed?.isEmpty ?? true) ? nil : trimmed,
            service: keychainService,
            account: sagAPIKeyAccount
        )
    }

    // MARK: - Playback
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
            // Closing this handle causes the wrapper to observe EOF and terminate the child process.
            if let h = lifetimeWriteHandle {
                try? h.close()
                lifetimeWriteHandle = nil
            }
        }
    }

    // MARK: - Public
    func play(
        _ text: String,
        voice: String? = nil,
        rate: Int? = nil
    ) throws -> Playback {
        let provider = Self.preferredProvider()

        if provider == .sag,
           let sagURL = Self.sagExecutableURL(),
           let apiKey = (try? Self.loadSAGAPIKey())
        {
            return try playSAG(text, voice: voice, rate: rate, sagURL: sagURL, apiKey: apiKey)
        }

        // Fallback (default): macOS say.
        return try playMacOSSay(text, voice: voice, rate: rate)
    }

    // MARK: - macOS say
    private func playMacOSSay(
        _ text: String,
        voice: String?,
        rate: Int?
    ) throws -> Playback {
        // We run the speech command through a small watchdog wrapper so that if this app crashes/exits,
        // the wrapper observes EOF on stdin (a pipe held open by this app) and terminates the child.
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
        args.append((voice?.isEmpty ?? true) ? "" : (voice ?? ""))
        args.append(rate.map(String.init) ?? "")
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

    // MARK: - SAG (ElevenLabs)
    private func playSAG(
        _ text: String,
        voice: String?,
        rate: Int?,
        sagURL: URL,
        apiKey: String
    ) throws -> Playback {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")

        let lifetimePipe = Pipe()
        process.standardInput = lifetimePipe

        guard let textData = text.data(using: .utf8) else {
            throw SaySpeechError.textEncodingFailed
        }
        let textB64 = textData.base64EncodedString()

        // Prefer env var over CLI args so the API key doesn't appear in argv.
        var env = ProcessInfo.processInfo.environment
        env["ELEVENLABS_API_KEY"] = apiKey
        process.environment = env

        let script = Self.sagWrapperPython

        var args: [String] = ["-c", script, "--"]
        args.append(sagURL.path)
        args.append((voice?.isEmpty ?? true) ? "" : (voice ?? ""))
        args.append(rate.map(String.init) ?? "")
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

    // MARK: - Keychain (SAG API key)
    private static let keychainService = "com.zats.Mouth"
    private static let sagAPIKeyAccount = "sag-elevenlabs-api-key"

    // Internal so Settings UI can show a filled SecureField when a key exists.
    static func loadSAGAPIKey() throws -> String? {
        try loadKeychainString(service: keychainService, account: sagAPIKeyAccount)
    }

    private static func loadKeychainString(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }
        guard let data = item as? Data else {
            return nil
        }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    private static func upsertKeychainString(_ value: String?, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if value == nil {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                return
            }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }

        guard let data = value?.data(using: .utf8) else {
            return
        }

        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }

        var add = query
        add[kSecValueData as String] = data

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: nil)
        }
    }

    // MARK: - SAG installation
    private static var sagExecutableResolved = false
    private static var sagExecutableCached: URL?

    static func sagExecutableURL() -> URL? {
        if sagExecutableResolved {
            return sagExecutableCached
        }
        sagExecutableResolved = true
        sagExecutableCached = resolveExecutable(named: "sag")
        return sagExecutableCached
    }

    private static func resolveExecutable(named name: String) -> URL? {
        let fm = FileManager.default

        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map(String.init))
        }

        // GUI apps sometimes don't inherit full shell PATH; add common Homebrew locations.
        candidates.append("/opt/homebrew/bin")
        candidates.append("/usr/local/bin")
        candidates.append("/usr/bin")

        var seen = Set<String>()
        for dir in candidates where !dir.isEmpty {
            if seen.contains(dir) { continue }
            seen.insert(dir)
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
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

    // Python wrapper arguments (after "--"):
    // 1) sag_path, 2) voice (or ""), 3) rate (or ""), 4) text_b64
    private static let sagWrapperPython = #"""
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

    if len(args) != 4:
        return 2

    sag_path = args[0]
    voice = args[1]
    rate = args[2]
    text_b64 = args[3]

    try:
        text = base64.b64decode(text_b64.encode("ascii")).decode("utf-8", errors="replace")
    except Exception:
        return 3

    sag_args = [sag_path, "speak"]
    if voice:
        sag_args += ["-v", voice]
    if rate:
        sag_args += ["-r", rate]
    sag_args.append(text)

    # stdin is inherited from this wrapper (a pipe owned by the parent app). We set sag's stdin
    # to DEVNULL to ensure it doesn't accidentally interact with our lifetime pipe.
    p = subprocess.Popen(sag_args, stdin=subprocess.DEVNULL)

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
