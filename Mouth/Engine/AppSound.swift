import AVFoundation
import Foundation

enum AppSoundError: Error, LocalizedError {
    case failedToLoad(underlying: Error)
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case let .failedToLoad(underlying):
            return "Failed to load sound: \(underlying)"
        case .playbackFailed:
            return "Failed to start playback"
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
/// Uses `AVAudioPlayer` for reliable sound playback + completion signaling.
final class AppSound {
    final class Playback: @unchecked Sendable {
        private let completion = PlaybackCompletion()
        private let player: AVAudioPlayer
        private let delegate: PlaybackDelegate

        fileprivate init(player: AVAudioPlayer) {
            self.player = player
            self.delegate = PlaybackDelegate(completion: completion)
            self.player.delegate = self.delegate
        }

        fileprivate func start() throws {
            guard player.play() else {
                throw AppSoundError.playbackFailed
            }
        }

        fileprivate func finish(_ result: Result<Void, Error>) async {
            await completion.finish(result)
        }

        func cancel() {
            player.stop()
            Task {
                await completion.finish(.failure(CancellationError()))
            }
        }

        /// Waits for playback to finish.
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

    private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
        private let completion: PlaybackCompletion

        init(completion: PlaybackCompletion) {
            self.completion = completion
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task {
                await completion.finish(.success(()))
            }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            let result: Result<Void, Error> = .failure(error ?? AppSoundError.playbackFailed)
            Task {
                await completion.finish(result)
            }
        }
    }

    func play(fileURL: URL) throws -> Playback {
        let player = try AVAudioPlayer(contentsOf: fileURL)
        player.prepareToPlay()
        player.currentTime = 0

        let playback = Playback(player: player)
        try playback.start()
        return playback
    }
}
