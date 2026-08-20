import AVFoundation
import Combine
import Foundation

enum AudioEngineError: LocalizedError {
    case fileUnavailable
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .fileUnavailable:
            return "That audio file couldn't be found. It may have been moved or deleted."
        case .decodeFailed:
            return "That file couldn't be read as audio."
        }
    }
}

/// One independent sound source: a player node feeding the shared mixer,
/// with its own volume and play state. Phase 1 uses a single channel;
/// Phase 2 creates one channel per active audio card.
@MainActor
final class SoundChannel: ObservableObject, Identifiable {
    let id: UUID

    @Published var isPlaying: Bool = false
    @Published var track: AudioTrack?
    @Published var volume: Float = 0.8 {
        didSet { playerNode.volume = volume }
    }

    let playerNode = AVAudioPlayerNode()
    fileprivate var audioFile: AVAudioFile?

    init(id: UUID = UUID()) {
        self.id = id
        playerNode.volume = volume
    }
}

/// Central AVAudioEngine wrapper. All sound channels attach to the same
/// engine and mix down through `mainMixerNode`, which is what makes
/// simultaneous playback (Phase 2) straightforward.
@MainActor
final class AudioEngine: ObservableObject {
    static let shared = AudioEngine()

    private let engine = AVAudioEngine()
    private var channels: [UUID: SoundChannel] = [:]

    private init() {
        engine.mainMixerNode.outputVolume = 1.0
    }

    func makeChannel() -> SoundChannel {
        let channel = SoundChannel()
        engine.attach(channel.playerNode)
        engine.connect(channel.playerNode, to: engine.mainMixerNode, format: nil)
        channels[channel.id] = channel
        return channel
    }

    func removeChannel(_ channel: SoundChannel) {
        stop(channel)
        engine.detach(channel.playerNode)
        channels.removeValue(forKey: channel.id)
    }

    func load(track: AudioTrack, into channel: SoundChannel) throws {
        guard let url = AudioLibraryService.shared.resolvedURL(for: track) else {
            throw AudioEngineError.fileUnavailable
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw AudioEngineError.fileUnavailable
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let file = try AVAudioFile(forReading: url)
            stop(channel)
            channel.audioFile = file
            channel.track = track
        } catch {
            throw AudioEngineError.decodeFailed
        }
    }

    func play(_ channel: SoundChannel) {
        guard let file = channel.audioFile else { return }
        ensureEngineRunning()

        channel.playerNode.stop()
        scheduleLoop(file: file, on: channel)
        channel.playerNode.play()
        channel.isPlaying = true
    }

    func pause(_ channel: SoundChannel) {
        channel.playerNode.pause()
        channel.isPlaying = false
    }

    func stop(_ channel: SoundChannel) {
        channel.playerNode.stop()
        channel.isPlaying = false
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("AudioEngine: failed to start engine: \(error)")
        }
    }

    /// Re-schedules the file each time it finishes so looping sounds
    /// (rain, white noise, etc.) play seamlessly without gaps.
    private func scheduleLoop(file: AVAudioFile, on channel: SoundChannel) {
        channel.playerNode.scheduleFile(file, at: nil) { [weak self, weak channel] in
            guard let self, let channel else { return }
            Task { @MainActor in
                guard channel.isPlaying, channel.track?.isLooping == true else { return }
                self.scheduleLoop(file: file, on: channel)
            }
        }
    }
}
