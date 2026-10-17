import Foundation
import MediaPlayer

/// Publishes the active channel to macOS Control Center / the Now Playing
/// widget, and relays play/pause commands back from it (media keys,
/// Control Center, headphone remotes).
@MainActor
final class NowPlayingService {
    static let shared = NowPlayingService()

    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var configured = false

    private init() {}

    func configure(togglePlayPause: @escaping () -> Void) {
        guard !configured else { return }
        configured = true

        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.stopCommand.isEnabled = false
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false

        commands.playCommand.addTarget { _ in
            togglePlayPause()
            return .success
        }
        commands.pauseCommand.addTarget { _ in
            togglePlayPause()
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { _ in
            togglePlayPause()
            return .success
        }
    }

    func update(for channel: SoundChannel) {
        guard let track = channel.track else {
            clear()
            return
        }

        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.category.displayName,
            MPMediaItemPropertyPlaybackDuration: channel.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: channel.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: channel.isPlaying ? 1.0 : 0.0,
        ]
        center.playbackState = channel.isPlaying ? .playing : .paused
    }

    func clear() {
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}
