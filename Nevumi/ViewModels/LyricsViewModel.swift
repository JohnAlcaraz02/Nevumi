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
    private var lastMusicKey: String?

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

    /// Starts polling `observer`'s estimated Music playback position so
    /// `currentLine` stays in sync. Call once, when the view appears.
    func attachToMusic(_ observer: MusicPlayerObserver) {
        pollTask?.cancel()
        pollTask = Task { [weak self, weak observer] in
            while !Task.isCancelled {
                if let observer { self?.tickMusic(observer) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func fetchLyrics(title: String, artist: String? = nil, durationHint: TimeInterval?) {
        lines = []
        currentLine = nil
        lookupFailed = false
        isLoading = true

        Task {
            do {
                lines = try await service.fetchSyncedLyrics(title: title, artist: artist, durationHint: durationHint)
            } catch {
                lookupFailed = true
            }
            isLoading = false
        }
    }

    /// Fetches lyrics when the Music-reported track changes; ignores
    /// position-only updates for the same track.
    func syncWithMusic(_ nowPlaying: MusicPlayerObserver.NowPlaying?) {
        guard let nowPlaying else {
            lastMusicKey = nil
            lines = []
            currentLine = nil
            return
        }
        let key = "\(nowPlaying.title)|\(nowPlaying.artist)"
        guard key != lastMusicKey else { return }
        lastMusicKey = key
        fetchLyrics(title: nowPlaying.title, artist: nowPlaying.artist, durationHint: nowPlaying.duration)
    }

    private func tick() {
        guard let channel, !lines.isEmpty else { return }
        let time = channel.currentTime
        currentLine = lines.last { $0.time <= time }
    }

    private func tickMusic(_ observer: MusicPlayerObserver) {
        guard !lines.isEmpty else { return }
        let time = observer.estimatedPosition()
        currentLine = lines.last { $0.time <= time }
    }
}
