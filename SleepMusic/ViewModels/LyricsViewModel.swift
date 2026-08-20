import Foundation

/// Fetches synced lyrics for the loaded track and tracks which line is
/// current against the channel's live playback position.
@MainActor
final class LyricsViewModel: ObservableObject {
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var currentLine: LyricLine?
    @Published private(set) var isLoading = false
    @Published private(set) var lookupFailed = false

    private let service = LyricsService.shared
    private weak var channel: SoundChannel?
    private var pollTask: Task<Void, Never>?
    private var lastSpotifyKey: String?

    /// Starts polling `channel`'s playback position so `currentLine` stays
    /// in sync. Call once, when the channel is created.
    func attach(to channel: SoundChannel) {
        self.channel = channel
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Starts polling `observer`'s estimated Spotify playback position so
    /// `currentLine` stays in sync. Call once, when the view appears.
    func attachToSpotify(_ observer: SpotifyObserver) {
        pollTask?.cancel()
        pollTask = Task { [weak self, weak observer] in
            while !Task.isCancelled {
                if let observer { self?.tickSpotify(observer) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func fetchLyrics(title: String, durationHint: TimeInterval?) {
        lines = []
        currentLine = nil
        lookupFailed = false
        isLoading = true

        Task {
            do {
                lines = try await service.fetchSyncedLyrics(forQuery: title, durationHint: durationHint)
            } catch {
                lookupFailed = true
            }
            isLoading = false
        }
    }

    /// Fetches lyrics when the Spotify-reported track changes; ignores
    /// position-only updates for the same track.
    func syncWithSpotify(_ nowPlaying: SpotifyObserver.NowPlaying?) {
        guard let nowPlaying else {
            lastSpotifyKey = nil
            lines = []
            currentLine = nil
            return
        }
        let key = "\(nowPlaying.title)|\(nowPlaying.artist)"
        guard key != lastSpotifyKey else { return }
        lastSpotifyKey = key
        fetchLyrics(title: nowPlaying.title, durationHint: nowPlaying.duration)
    }

    private func tick() {
        guard let channel, !lines.isEmpty else { return }
        let time = channel.currentTime
        currentLine = lines.last { $0.time <= time }
    }

    private func tickSpotify(_ observer: SpotifyObserver) {
        guard !lines.isEmpty else { return }
        let time = observer.estimatedPosition()
        currentLine = lines.last { $0.time <= time }
    }
}
