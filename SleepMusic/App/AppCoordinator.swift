import Combine
import Foundation

/// Owns the background services and starts them the moment the app
/// launches, independent of any window being open — so Spotify polling,
/// the notch pill, and the sleep overlay all work as soon as SleepMusic is
/// running in the background, with nothing to open.
@MainActor
final class AppCoordinator: ObservableObject {
    let spotify = SpotifyObserver()
    let lyrics = LyricsViewModel()

    private var cancellables = Set<AnyCancellable>()

    init() {
        lyrics.attachToSpotify(spotify)
        NotchController.shared.configure(spotify: spotify)

        spotify.$nowPlaying
            .sink { [weak self] nowPlaying in
                guard let self else { return }
                lyrics.syncWithSpotify(nowPlaying)
                updateNotch()
            }
            .store(in: &cancellables)

        lyrics.$currentLine
            .sink { [weak self] _ in self?.updateNotch() }
            .store(in: &cancellables)

        SleepOverlayController.shared.observeLockEvents(
            spotify: spotify,
            lyrics: lyrics,
            isPlaying: { [weak self] in self?.spotify.nowPlaying?.isPlaying ?? false }
        )

        spotify.start()
    }

    private func updateNotch() {
        NotchController.shared.update(
            title: spotify.nowPlaying?.title ?? "",
            artist: spotify.nowPlaying?.artist ?? "",
            isPlaying: spotify.nowPlaying?.isPlaying ?? false,
            artworkURL: spotify.nowPlaying?.artworkURL,
            duration: spotify.nowPlaying?.duration ?? 0,
            currentLyric: lyrics.currentLine?.text
        )
    }
}
