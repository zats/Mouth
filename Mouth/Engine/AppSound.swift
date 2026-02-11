import AudioToolbox
import Foundation

enum AppSoundError: Error, LocalizedError {
    case failedToLoad(underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .failedToLoad(underlying):
            return "Failed to load sound: \(underlying)"
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

/// In-process sound playback wrapper (no CLI process spawn).
///
/// Uses `AudioToolbox` system sound IDs and caches the loaded sound to avoid
/// per-play disposal timing issues.
final class AppSound {
    final class Playback: @unchecked Sendable {
        private let completion = PlaybackCompletion()

        func finish(_ result: Result<Void, Error>) async {
            await completion.finish(result)
        }

        func cancel() {
            Task {
                await completion.finish(.failure(CancellationError()))
            }
        }

        func wait() async throws {
            try await withTaskCancellationHandler {
                try await completion.wait()
            } onCancel: {
                Task {
                    await completion.finish(.failure(CancellationError()))
                }
            }
        }
    }

    private var cachedURL: URL?
    private var cachedSoundID: SystemSoundID = 0

    deinit {
        if cachedSoundID != 0 {
            AudioServicesDisposeSystemSoundID(cachedSoundID)
        }
    }

    func play(fileURL: URL) throws -> Playback {
        if cachedURL != fileURL || cachedSoundID == 0 {
            if cachedSoundID != 0 {
                AudioServicesDisposeSystemSoundID(cachedSoundID)
                cachedSoundID = 0
            }

            var sid: SystemSoundID = 0
            let st = AudioServicesCreateSystemSoundID(fileURL as CFURL, &sid)
            guard st == kAudioServicesNoError, sid != 0 else {
                throw AppSoundError.failedToLoad(underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(st)))
            }

            cachedURL = fileURL
            cachedSoundID = sid
        }

        let playback = Playback()
        AudioServicesPlaySystemSoundWithCompletion(cachedSoundID) {
            Task {
                await playback.finish(.success(()))
            }
        }
        return playback
    }
}
