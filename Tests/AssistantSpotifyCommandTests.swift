import Foundation

// swiftc -module-cache-path /tmp/nevumi-swift-module-cache
// Nevumi/Services/SpotifyObserver.swift Tests/AssistantSpotifyCommandTests.swift
// -o /tmp/nevumi-spotify-tests
@main
struct AssistantSpotifyCommandTests {
    static func main() {
        let cases: [(String, AssistantSpotifyCommand)] = [
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
        ]
        for (request, expected) in cases {
            precondition(AssistantSpotifyCommand(request: request) == expected, request)
        }
        for request in ["play Buwan by Juan Karlos on Spotify", "play Music by Madonna",
                        "what song is playing?", "next song", "open calendar",
                        "explain how to play music", "", "please"] {
            precondition(AssistantSpotifyCommand(request: request) == nil, request)
        }
        print("Spotify command parsing passed (\(cases.count + 8) cases).")
    }
}
