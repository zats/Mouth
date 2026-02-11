import AudioToolbox
import Foundation

enum AppSoundError: Error, LocalizedError {
    case failedToLoad(underlying: Error)
    case failedToStart

    var errorDescription: String? {
        switch self {
        case let .failedToLoad(underlying):
            return "Failed to load sound: \(underlying)"
        case .failedToStart:
            return "Failed to start sound playback"
        }
    }
}

private actor PlaybackCompletion {
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        if self.result != nil { return }
        self.result = result
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    func wait() async throws {
        if let result {
            return try result.get()
        }

        try await withCheckedThrowingContinuation { cont in
            continuation = cont
        }
    }
}

private final class SoundIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sid: SystemSoundID

    init(_ sid: SystemSoundID) {
        self.sid = sid
    }

    func disposeIfNeeded() {
        let toDispose: SystemSoundID? = lock.withLock {
            guard sid != 0 else { return nil }
            let v = sid
            sid = 0
            return v
        }

        if let toDispose {
            AudioServicesDisposeSystemSoundID(toDispose)
        }
    }
}

/// In-process sound playback wrapper (no CLI process spawn).
final class AppSound {
    final class Playback: @unchecked Sendable {
        let id: UUID

        fileprivate let completion = PlaybackCompletion()
        private let soundIDBox: SoundIDBox
        fileprivate var didFinishOrCancel = false

        fileprivate init(id: UUID, soundIDBox: SoundIDBox) {
            self.id = id
            self.soundIDBox = soundIDBox
        }

        deinit {
            cancel()
        }

        var isRunning: Bool {
            !didFinishOrCancel
        }

        func cancel() {
            if didFinishOrCancel { return }
            didFinishOrCancel = true

            soundIDBox.disposeIfNeeded()

            Task { await completion.finish(.failure(CancellationError())) }
        }

        func wait() async throws {
            try await completion.wait()
        }
    }

    func play(fileURL: URL, volume: Float? = nil) throws -> Playback {
        _ = volume // SystemSound playback has no per-sound volume control.

        var sid: SystemSoundID = 0
        let st = AudioServicesCreateSystemSoundID(fileURL as CFURL, &sid)
        guard st == kAudioServicesNoError, sid != 0 else {
            throw AppSoundError.failedToLoad(underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(st)))
        }

        let box = SoundIDBox(sid)
        let playback = Playback(id: UUID(), soundIDBox: box)

        AudioServicesPlaySystemSoundWithCompletion(sid) { [weak playback] in
            box.disposeIfNeeded()
            guard let playback else { return }

            if playback.didFinishOrCancel {
                // Cancel already handled disposal/completion.
                return
            }

            playback.didFinishOrCancel = true
            Task { await playback.completion.finish(.success(())) }
        }

        return playback
    }
}
