import AVFoundation
import Foundation

enum AppSoundError: Error, LocalizedError {
    case failedToLoad(underlying: Error)
    case failedToStart
    case playbackFailed
    case decodeFailed(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case let .failedToLoad(underlying):
            return "Failed to load sound: \(underlying)"
        case .failedToStart:
            return "Failed to start sound playback"
        case .playbackFailed:
            return "Sound playback failed"
        case let .decodeFailed(underlying):
            if let underlying {
                return "Sound decode failed: \(underlying)"
            }
            return "Sound decode failed"
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
final class AppSound {
    final class Playback: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        let id: UUID

        private let player: AVAudioPlayer
        private let completion = PlaybackCompletion()
        private var started = false

        fileprivate init(id: UUID, player: AVAudioPlayer) {
            self.id = id
            self.player = player
            super.init()
            self.player.delegate = self
        }

        deinit {
            cancel()
        }

        var isRunning: Bool {
            player.isPlaying
        }

        fileprivate func start() throws {
            if started { return }
            started = true

            player.currentTime = 0
            player.prepareToPlay()
            guard player.play() else {
                Task { await completion.finish(.failure(AppSoundError.failedToStart)) }
                throw AppSoundError.failedToStart
            }
        }

        func cancel() {
            if !player.isPlaying {
                Task { await completion.finish(.failure(CancellationError())) }
                return
            }
            player.stop()
            Task { await completion.finish(.failure(CancellationError())) }
        }

        func wait() async throws {
            try await completion.wait()
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task {
                await completion.finish(flag ? .success(()) : .failure(AppSoundError.playbackFailed))
            }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            Task {
                await completion.finish(.failure(AppSoundError.decodeFailed(underlying: error)))
            }
        }
    }

    func play(fileURL: URL, volume: Float? = nil) throws -> Playback {
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            if let volume {
                player.volume = volume
            }
            let playback = Playback(id: UUID(), player: player)
            try playback.start()
            return playback
        } catch {
            throw AppSoundError.failedToLoad(underlying: error)
        }
    }
}
