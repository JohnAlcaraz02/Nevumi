import Combine
import Foundation

/// Owns the background services and starts them the moment the app
/// launches, independent of any window being open — so Music polling,
/// the notch pill, and the sleep overlay all work as soon as Nevumi is
/// running in the background, with nothing to open.
@MainActor
final class AppCoordinator: ObservableObject {
    let music = MusicPlayerObserver()
    let lyrics = LyricsViewModel()
    let windowManagement = WindowManagementController {
        LongScreenshotController.shared.start()
    }

    private var cancellables = Set<AnyCancellable>()
    private var quickAssistantHotKey: GlobalHotKeyController?

    init() {
        lyrics.attachToMusic(music)
        NotchController.shared.configure(music: music)
        QuickAssistantWindowController.shared.configure(music: music, lyrics: lyrics)
        quickAssistantHotKey = GlobalHotKeyController {
            QuickAssistantWindowController.shared.toggle()
        }

        music.$nowPlaying
            .sink { [weak self] nowPlaying in
                guard let self else { return }
                lyrics.syncWithMusic(nowPlaying)
                updateNotch()
            }
            .store(in: &cancellables)

        music.$isRunning
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateNotch() }
            .store(in: &cancellables)

        music.$activePlayer
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateNotch() }
            .store(in: &cancellables)

        lyrics.$currentLine
            .sink { [weak self] _ in self?.updateNotch() }
            .store(in: &cancellables)

        SleepOverlayController.shared.observeLockEvents(
            music: music,
            lyrics: lyrics,
            isPlaying: { [weak self] in self?.music.nowPlaying?.isPlaying ?? false }
        )

        music.start()
    }

    private func updateNotch() {
        NotchController.shared.update(
            title: music.nowPlaying?.title ?? music.activePlayer.displayName,
            artist: music.nowPlaying?.artist ?? "Ready to play",
            isPlaying: music.nowPlaying?.isPlaying ?? false,
            isMusicRunning: music.isRunning,
            artworkURL: music.nowPlaying?.artworkURL,
            duration: music.nowPlaying?.duration ?? 0,
            currentLyric: lyrics.currentLine?.text
        )
    }
}
