import AppKit

enum MusicPlayer: String, CaseIterable {
    case spotify, appleMusic

    var displayName: String { self == .spotify ? "Spotify" : "Apple Music" }
    var applicationName: String { self == .spotify ? "Spotify" : "Music" }
    var bundleIdentifier: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }

    static func requested(in request: String) -> MusicPlayer? {
        let value = request.lowercased()
        if value.range(of: #"\bapple music\b"#, options: .regularExpression) != nil { return .appleMusic }
        if value.range(of: #"\bspotify\b"#, options: .regularExpression) != nil { return .spotify }
        return nil
    }

    /// Keep controls stable when both apps play; otherwise follow the playing app.
    static func select(current: MusicPlayer, running: Set<MusicPlayer>,
                       playing: Set<MusicPlayer>, withTrack: Set<MusicPlayer>) -> MusicPlayer {
        if playing.contains(current) { return current }
        if let player = allCases.first(where: { playing.contains($0) }) { return player }
        if withTrack.contains(current) { return current }
        if let player = allCases.first(where: { withTrack.contains($0) }) { return player }
        if running.contains(current) { return current }
        return allCases.first(where: { running.contains($0) }) ?? current
    }
}

enum AssistantMusicCommand: Equatable {
    case open, play, pause, toggle, next, previous

    init?(request: String) {
        let command = request.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"^(?:(?:can|could|would) you\s+)?(?:please\s+)?"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+please$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\bapple music\b"#, with: "spotify", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        switch command {
        case "open spotify", "launch spotify", "start spotify": self = .open
        case "play", "resume", "play music", "play some music", "play something", "play a song",
             "play spotify", "play music on spotify", "play some music on spotify",
             "play on spotify", "resume music", "resume playback", "resume spotify",
             "resume on spotify", "resume music on spotify", "resume playback on spotify",
             "start music", "start playing music", "open spotify and play",
             "open spotify and play music", "open spotify and play some music": self = .play
        case "pause", "pause music", "pause spotify", "pause playback", "pause the music",
             "pause music on spotify", "pause playback on spotify", "pause on spotify": self = .pause
        case "play or pause", "toggle music", "toggle playback", "toggle spotify",
             "toggle playback on spotify": self = .toggle
        case "next", "next song", "skip", "skip song", "skip track", "next song on spotify",
             "skip on spotify": self = .next
        case "previous", "previous song", "previous track", "go back", "previous song on spotify": self = .previous
        default: return nil
        }
    }
}

/// Shares native Spotify and Music.app playback with the notch, assistant and Sleep Mode.
@MainActor
final class MusicPlayerObserver: ObservableObject {
    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var duration: TimeInterval
        var artworkURL: URL?
    }

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var isRunning = false
    @Published private(set) var activePlayer: MusicPlayer

    private var timer: Timer?
    private var lastPosition: TimeInterval = 0
    private var lastPositionDate = Date.distantPast
    private var artworkKey: String?
    private var artworkURL: URL?

    init() {
        activePlayer = UserDefaults.standard.string(forKey: "musicPlayer")
            .flatMap(MusicPlayer.init(rawValue:)) ??
            (NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicPlayer.spotify.bundleIdentifier) == nil
             ? .appleMusic : .spotify)
    }

    func togglePlayPause() { send("playpause") }
    func skipToNext() { send("next track") }
    func skipToPrevious() { send("previous track") }

    func toggleShuffle() {
        send(activePlayer == .spotify ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled")
    }

    func toggleRepeat() {
        if activePlayer == .spotify {
            send("set repeating to not repeating")
        } else {
            send("if song repeat is off then\nset song repeat to all\nelse\nset song repeat to off\nend if")
        }
    }

    private func send(_ action: String) {
        guard isAppRunning(activePlayer) else { return }
        _ = try? execute("tell application \"\(activePlayer.applicationName)\"\n\(action)\nend tell", player: activePlayer)
        poll()
    }

    struct PlaybackError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func open(_ player: MusicPlayer) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) else {
            throw PlaybackError(message: "Install \(player.displayName) on this Mac first.")
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } catch {
            throw PlaybackError(message: "I couldn’t open \(player.displayName). Try opening it from Applications.")
        }
        try Task.checkCancellation()
        activePlayer = player
        UserDefaults.standard.set(player.rawValue, forKey: "musicPlayer")
    }

    func perform(_ command: AssistantMusicCommand, player requestedPlayer: MusicPlayer? = nil) async throws -> String {
        let player = requestedPlayer ?? activePlayer
        // Pausing or skipping should never launch a closed player.
        if [.pause, .next, .previous].contains(command), !isAppRunning(player) {
            return "\(player.displayName) is closed, so there’s no playback to control."
        }
        try await open(player)
        if command == .open { poll(); return "Opened \(player.displayName)." }
        let action: String
        switch command {
        case .play: action = "play"
        case .pause: action = "pause"
        case .toggle: action = "playpause"
        case .next: action = "next track"
        case .previous: action = "previous track"
        case .open: action = ""
        }
        var state = try execute("tell application \"\(player.applicationName)\"\n\(action)\nreturn player state as string\nend tell", player: player).stringValue
        if command == .play {
            for _ in 0..<8 where state != "playing" {
                try await Task.sleep(for: .milliseconds(250))
                state = try execute("tell application \"\(player.applicationName)\" to return player state as string", player: player).stringValue
            }
        }
        poll()
        if command == .next { return "Skipping to the next \(player.displayName) track." }
        if command == .previous { return "Going back to the previous \(player.displayName) track." }
        if state == "playing" { return "Playing music in \(player.displayName)." }
        if command == .play {
            throw PlaybackError(message: "\(player.displayName) is open. Choose a song or playlist first, then I can resume it for you.")
        }
        return "\(player.displayName) playback paused."
    }

    /// Navigate to search results; selecting a catalog track remains in the music app.
    func openSearch(_ query: String, player: MusicPlayer) async throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty,
              let url = URL(string: player == .spotify ? "spotify:search:" + encoded : "music://music.apple.com/search?term=" + encoded)
        else { throw PlaybackError(message: "Couldn’t search for that song.") }
        try await open(player)
        guard NSWorkspace.shared.open(url) else {
            throw PlaybackError(message: "Couldn’t open \(player.displayName) search results.")
        }
    }

    @discardableResult
    private func execute(_ source: String, player: MusicPlayer) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw PlaybackError(message: "Couldn’t prepare the \(player.displayName) command.")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                throw PlaybackError(message: "Allow Nevumi to control \(player.displayName) in System Settings → Privacy & Security → Automation.")
            }
            throw PlaybackError(message: "\(player.displayName) couldn’t complete that request. Check that you’re signed in and try again.")
        }
        return result
    }

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func estimatedPosition() -> TimeInterval {
        guard nowPlaying?.isPlaying == true else { return lastPosition }
        return min(nowPlaying?.duration ?? .greatestFiniteMagnitude,
                   lastPosition + Date().timeIntervalSince(lastPositionDate))
    }

    private func isAppRunning(_ player: MusicPlayer) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).isEmpty
    }

    private func poll() {
        let running = Set(MusicPlayer.allCases.filter(isAppRunning))
        var tracks: [MusicPlayer: (NowPlaying, TimeInterval, String)] = [:]
        for player in running {
            if let track = queryNowPlaying(player) { tracks[player] = track }
        }
        let playing = Set(tracks.compactMap { $0.value.0.isPlaying ? $0.key : nil })
        activePlayer = MusicPlayer.select(current: activePlayer, running: running,
                                         playing: playing, withTrack: Set(tracks.keys))
        isRunning = !running.isEmpty
        guard let (currentTrack, position, key) = tracks[activePlayer] else {
            nowPlaying = nil
            lastPosition = 0
            lastPositionDate = .distantPast
            return
        }
        var track = currentTrack
        if activePlayer == .appleMusic { track.artworkURL = musicArtwork(for: key) }
        nowPlaying = track
        lastPosition = position
        lastPositionDate = Date()
    }

    static func nowPlayingScript(for player: MusicPlayer) -> String {
        let duration = player == .spotify ? "(duration of current track) / 1000" : "duration of current track"
        let artwork = player == .spotify ? "artwork url of current track" : "persistent ID of current track"
        return """
        tell application "\(player.applicationName)"
            return {name of current track, artist of current track, player state as string, player position, \(duration), \(artwork)}
        end tell
        """
    }

    private func queryNowPlaying(_ player: MusicPlayer) -> (NowPlaying, TimeInterval, String)? {
        guard let output = try? execute(Self.nowPlayingScript(for: player), player: player), output.numberOfItems == 6,
              let title = output.atIndex(1)?.stringValue, let artist = output.atIndex(2)?.stringValue,
              let state = output.atIndex(3)?.stringValue,
              let position = output.atIndex(4)?.doubleValue,
              let duration = output.atIndex(5)?.doubleValue,
              position.isFinite, duration.isFinite, duration > 0 else { return nil }
        let artwork = output.atIndex(6)?.stringValue ?? ""
        return (NowPlaying(title: title, artist: artist, isPlaying: state == "playing", duration: duration,
                           artworkURL: player == .spotify ? URL(string: artwork) : nil),
                position, "\(artwork)|\(title)|\(artist)")
    }

    private func musicArtwork(for key: String) -> URL? {
        guard artworkKey != key else { return artworkURL }
        artworkKey = key
        if let artworkURL { try? FileManager.default.removeItem(at: artworkURL) }
        artworkURL = nil
        guard let result = try? execute("tell application \"Music\" to return raw data of artwork 1 of current track", player: .appleMusic),
              let image = NSImage(data: result.data), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nevumi-music-\(UUID().uuidString).png")
        do { try data.write(to: url, options: .atomic); artworkURL = url } catch { return nil }
        return url
    }
}
