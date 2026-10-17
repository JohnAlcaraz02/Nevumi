import AppKit

enum AssistantSpotifyCommand: Equatable {
    case open, play, pause, toggle

    init?(request: String) {
        let command = request.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"^(?:(?:can|could|would) you\s+)?(?:please\s+)?"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+please$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        switch command {
        case "open spotify", "launch spotify", "start spotify": self = .open
        case "play", "resume", "play music", "play some music", "play something", "play a song",
             "play spotify", "play music on spotify", "play some music on spotify",
             "play on spotify", "resume music", "resume playback", "resume spotify",
             "start music", "start playing music", "open spotify and play",
             "open spotify and play music", "open spotify and play some music": self = .play
        case "pause", "pause music", "pause spotify", "pause playback", "pause the music": self = .pause
        case "play or pause", "toggle music", "toggle playback": self = .toggle
        default: return nil
        }
    }
}

/// Polls Spotify (if running) for its currently playing track via Apple
/// Events, so Nevumi can show what's playing without importing a file.
/// Requires the user to grant Automation access on first use.
@MainActor
final class SpotifyObserver: ObservableObject {
    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var duration: TimeInterval
        var artworkURL: URL?
    }

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var isRunning = false

    private var timer: Timer?
    private var lastPosition: TimeInterval = 0
    private var lastPositionDate = Date.distantPast

    private static let script = NSAppleScript(source: [
        "if application \"Spotify\" is running then",
        "    tell application \"Spotify\"",
        "        set trackDuration to (duration of current track) / 1000",
        "        return (name of current track) & \"||\" & (artist of current track) & \"||\" & (player state as string) & \"||\" & (player position as string) & \"||\" & (trackDuration as string) & \"||\" & (artwork url of current track)",
        "    end tell",
        "else",
        "    return \"NOT_RUNNING\"",
        "end if",
    ].joined(separator: "\n"))

    /// Toggles play/pause in Spotify. Fire-and-forget, like the polling script.
    func togglePlayPause() {
        NSAppleScript(source: "tell application \"Spotify\" to playpause")?.executeAndReturnError(nil)
    }

    func skipToNext() {
        NSAppleScript(source: "tell application \"Spotify\" to next track")?.executeAndReturnError(nil)
    }

    func skipToPrevious() {
        NSAppleScript(source: "tell application \"Spotify\" to previous track")?.executeAndReturnError(nil)
    }

    enum PlaybackError: LocalizedError {
        case notInstalled, launchFailed, automationDenied, commandFailed, noPlayback

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Install Spotify on this Mac first."
            case .launchFailed: return "I couldn’t open Spotify. Try opening it from Applications."
            case .automationDenied: return "Allow Nevumi to control Spotify in System Settings → Privacy & Security → Automation."
            case .commandFailed: return "Spotify couldn’t complete that request. Check that you’re signed in and try again."
            case .noPlayback: return "Spotify is open. Choose a song or playlist to start listening, then I can resume it for you."
            }
        }
    }

    /// Wait for launch to finish before sending playback events to Spotify.
    func openSpotify() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            throw PlaybackError.notInstalled
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } catch {
            throw PlaybackError.launchFailed
        }
        try Task.checkCancellation()
    }

    func perform(_ command: AssistantSpotifyCommand) async throws -> String {
        // Pausing should never launch a closed player.
        if command == .pause,
           NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty {
            return "Spotify is closed, so there’s nothing to pause."
        }
        try await openSpotify()
        if command == .open { return "Opened Spotify." }
        let action: String
        switch command {
        case .play: action = "play"
        case .pause: action = "pause"
        case .toggle: action = "playpause"
        case .open: return "Opened Spotify."
        }
        var state = try executePlaybackScript("tell application \"Spotify\"\n\(action)\nreturn player state as string\nend tell")
        // A newly launched Spotify may need a moment to restore its queue.
        if command == .play {
            for _ in 0..<8 where state != "playing" {
                try await Task.sleep(for: .milliseconds(250))
                state = try executePlaybackScript("tell application \"Spotify\" to return player state as string")
            }
        }
        poll()
        if state == "playing" { return "Playing music in Spotify." }
        if command == .play { throw PlaybackError.noPlayback }
        return "Spotify playback paused."
    }

    /// Search URIs navigate to results; they are not playable track URIs.
    func openSearch(_ query: String) async throws {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty,
              let url = URL(string: "spotify:search:" + encoded) else { throw PlaybackError.commandFailed }
        try await openSpotify()
        guard NSWorkspace.shared.open(url) else { throw PlaybackError.commandFailed }
    }

    private func executePlaybackScript(_ source: String) throws -> String? {
        guard let script = NSAppleScript(source: source) else { throw PlaybackError.commandFailed }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                throw PlaybackError.automationDenied
            }
            throw PlaybackError.commandFailed
        }
        return result.stringValue
    }

    func toggleShuffle() {
        NSAppleScript(source: "tell application \"Spotify\" to set shuffling to not shuffling")?.executeAndReturnError(nil)
    }

    func toggleRepeat() {
        NSAppleScript(source: "tell application \"Spotify\" to set repeating to not repeating")?.executeAndReturnError(nil)
    }

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
        let isSpotifyRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.spotify.client"
        ).isEmpty

        if isRunning != isSpotifyRunning {
            isRunning = isSpotifyRunning
        }

        guard isSpotifyRunning else {
            nowPlaying = nil
            lastPosition = 0
            lastPositionDate = .distantPast
            return
        }

        guard let (result, position) = Self.queryNowPlaying() else {
            nowPlaying = nil
            lastPosition = 0
            lastPositionDate = .distantPast
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
        guard parts.count == 6,
              let position = Double(parts[3]),
              let duration = Double(parts[4])
        else { return nil }
        let nowPlaying = NowPlaying(
            title: parts[0],
            artist: parts[1],
            isPlaying: parts[2] == "playing",
            duration: duration,
            artworkURL: URL(string: parts[5])
        )
        return (nowPlaying, position)
    }
}
