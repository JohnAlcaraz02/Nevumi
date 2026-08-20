import AppKit

/// Polls Spotify (if running) for its currently playing track via Apple
/// Events, so SleepMusic can show what's playing without importing a file.
/// Requires the user to grant Automation access on first use.
@MainActor
final class SpotifyObserver: ObservableObject {
    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var duration: TimeInterval
    }

    @Published private(set) var nowPlaying: NowPlaying?

    private var timer: Timer?
    private var lastPosition: TimeInterval = 0
    private var lastPositionDate = Date.distantPast

    private static let script = NSAppleScript(source: [
        "if application \"Spotify\" is running then",
        "    tell application \"Spotify\"",
        "        set trackDuration to (duration of current track) / 1000",
        "        return (name of current track) & \"||\" & (artist of current track) & \"||\" & (player state as string) & \"||\" & (player position as string) & \"||\" & (trackDuration as string)",
        "    end tell",
        "else",
        "    return \"NOT_RUNNING\"",
        "end if",
    ].joined(separator: "\n"))

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Spotify's playback position, interpolated from wall-clock time since
    /// the last poll so lyric sync doesn't stutter between polls.
    func estimatedPosition() -> TimeInterval {
        guard nowPlaying?.isPlaying == true else { return lastPosition }
        return lastPosition + Date().timeIntervalSince(lastPositionDate)
    }

    private func poll() {
        guard let (result, position) = Self.queryNowPlaying() else {
            nowPlaying = nil
            return
        }
        nowPlaying = result
        lastPosition = position
        lastPositionDate = Date()
    }

    private static func queryNowPlaying() -> (NowPlaying, TimeInterval)? {
        guard let script else { return nil }
        var errorDict: NSDictionary?
        let output = script.executeAndReturnError(&errorDict)
        guard errorDict == nil, let raw = output.stringValue, raw != "NOT_RUNNING" else { return nil }
        let parts = raw.components(separatedBy: "||")
        guard parts.count == 5,
              let position = Double(parts[3]),
              let duration = Double(parts[4])
        else { return nil }
        let nowPlaying = NowPlaying(
            title: parts[0],
            artist: parts[1],
            isPlaying: parts[2] == "playing",
            duration: duration
        )
        return (nowPlaying, position)
    }
}
