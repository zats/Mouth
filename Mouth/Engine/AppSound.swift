import AVFoundation
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

/// In-process sound playback wrapper (no CLI process spawn).
///
/// Uses `AVAudioPlayer` and a lightweight poller to avoid delegate/lifetime issues.
final class AppSound {
    final class Playback: @unchecked Sendable {
        let id: UUID

        private let completion = PlaybackCompletion()
        private var player: AVAudioPlayer?
        private var monitorTask: Task<Void, Never>?

        fileprivate init(id: UUID, player: AVAudioPlayer) {
            self.id = id
            self.player = player

            monitorTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let stillPlaying = self.player?.isPlaying ?? false
                    if !stillPlaying { break }
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }

                await self.completion.finish(.success(()))
            }
        }

        deinit {
            cancel()
        }

        var isRunning: Bool {
            player?.isPlaying ?? false
        }

        func cancel() {
            monitorTask?.cancel()
            monitorTask = nil

            player?.stop()
            player = nil

            Task { await completion.finish(.failure(CancellationError())) }
        }

        func wait() async throws {
            try await completion.wait()
        }
    }

    func play(fileURL: URL, volume: Float? = nil) throws -> Playback {
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            if let volume {
                player.volume = volume
            }
            player.prepareToPlay()
            guard player.play() else {
                throw AppSoundError.failedToStart
            }
            return Playback(id: UUID(), player: player)
        } catch {
            throw AppSoundError.failedToLoad(underlying: error)
        }
    }
}

