import Foundation

/// One time-stamped line from a synced (.lrc) lyrics file.
struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}
