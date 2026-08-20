import Foundation

/// Drives the single-track player screen: import, load, play/pause, volume.
@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var channel: SoundChannel
    @Published var errorMessage: String?

    private let engine = AudioEngine.shared
    private let library = AudioLibraryService.shared

    init() {
        channel = engine.makeChannel()
    }

    func importAndLoad(category: AudioCategory) {
        library.importTrack(category: category) { [weak self] track in
            guard let self, let track else { return }
            self.load(track: track)
        }
    }

    func load(track: AudioTrack) {
        do {
            try engine.load(track: track, into: channel)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayPause() {
        guard channel.track != nil else { return }
        if channel.isPlaying {
            engine.pause(channel)
        } else {
            engine.play(channel)
        }
    }

    func setVolume(_ value: Float) {
        channel.volume = value
    }
}
