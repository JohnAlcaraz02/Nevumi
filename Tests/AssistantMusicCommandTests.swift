import AppKit

// swiftc -module-cache-path /tmp/nevumi-swift-module-cache
// Nevumi/Services/MusicPlayerObserver.swift Tests/AssistantMusicCommandTests.swift
// -o /tmp/nevumi-music-tests
@main
struct AssistantMusicCommandTests {
    @MainActor
    static func main() {
        let cases: [(String, AssistantMusicCommand)] = [
            ("open Spotify", .open),
            ("Could you please open Spotify?", .open),
            ("launch spotify please", .open),
            ("play", .play),
            ("play music", .play),
            ("Play some music on Spotify!", .play),
            ("open Spotify and play music", .play),
            ("please resume playback", .play),
            ("pause", .pause),
            ("can you pause the music?", .pause),
            ("play or pause", .toggle),
            ("toggle playback", .toggle),
            ("Open Apple Music", .open),
            ("Could you please open Apple Music?", .open),
            ("Play some music on Apple Music!", .play),
            ("open Apple Music and play music", .play),
            ("resume on Apple Music", .play),
            ("pause Apple Music", .pause),
            ("pause music on Apple Music", .pause),
            ("toggle playback on Apple Music", .toggle),
            ("next song", .next),
            ("next song on Apple Music", .next),
            ("previous song on Spotify", .previous),
        ]
        for (request, expected) in cases {
            precondition(AssistantMusicCommand(request: request) == expected, request)
        }
        for request in ["play Buwan by Juan Karlos on Spotify", "play Music by Madonna",
                        "what song is playing?", "open calendar",
                        "play Buwan on Apple Music",
                        "explain how to play music", "", "please"] {
            precondition(AssistantMusicCommand(request: request) == nil, request)
        }
        precondition(MusicPlayer.requested(in: "pause Apple Music") == .appleMusic)
        precondition(MusicPlayer.requested(in: "play on Spotify") == .spotify)
        precondition(MusicPlayer.requested(in: "play music") == nil)
        precondition(MusicPlayer.select(current: .spotify, running: [.spotify, .appleMusic],
            playing: [.appleMusic], withTrack: [.spotify, .appleMusic]) == .appleMusic)
        precondition(MusicPlayer.select(current: .appleMusic, running: [.spotify, .appleMusic],
            playing: [.spotify, .appleMusic], withTrack: [.spotify, .appleMusic]) == .appleMusic)
        precondition(MusicPlayer.select(current: .spotify, running: [.appleMusic],
            playing: [], withTrack: [.appleMusic]) == .appleMusic)
        precondition(MusicPlayer.select(current: .appleMusic, running: [],
            playing: [], withTrack: []) == .appleMusic)
        // Compile the production polling scripts against the installed app dictionaries.
        // No script is executed, so these checks don't launch or change playback.
        for player in MusicPlayer.allCases {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) != nil else { continue }
            var error: NSDictionary?
            let script = NSAppleScript(source: MusicPlayerObserver.nowPlayingScript(for: player))!
            precondition(script.compileAndReturnError(&error), "\(player): \(String(describing: error))")
        }
        print("Music command parsing, provider routing, selection and script compilation passed.")
    }
}
