import Foundation

/// The fixed set of sound sources the app understands.
/// Adding a new ambient sound later means adding one case here.
enum AudioCategory: String, Codable, CaseIterable, Identifiable {
    case music
    case rain
    case ocean
    case fireplace
    case forest
    case whiteNoise
    case brownNoise
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .music: return "Music"
        case .rain: return "Rain"
        case .ocean: return "Ocean"
        case .fireplace: return "Fireplace"
        case .forest: return "Forest"
        case .whiteNoise: return "White Noise"
        case .brownNoise: return "Brown Noise"
        case .custom: return "Custom"
        }
    }

    var emoji: String {
        switch self {
        case .music: return "🎵"
        case .rain: return "🌧"
        case .ocean: return "🌊"
        case .fireplace: return "🔥"
        case .forest: return "🌲"
        case .whiteNoise: return "🤍"
        case .brownNoise: return "🤎"
        case .custom: return "📁"
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .rain: return "cloud.rain"
        case .ocean: return "water.waves"
        case .fireplace: return "flame"
        case .forest: return "tree"
        case .whiteNoise: return "waveform"
        case .brownNoise: return "waveform.path"
        case .custom: return "folder"
        }
    }
}
