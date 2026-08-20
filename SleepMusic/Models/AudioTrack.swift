import Foundation

/// A single imported audio file, referenced only by a security-scoped
/// bookmark — the app never copies or uploads the underlying file.
struct AudioTrack: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var category: AudioCategory
    var bookmarkData: Data
    var isLooping: Bool

    init(
        id: UUID = UUID(),
        name: String,
        category: AudioCategory,
        bookmarkData: Data,
        isLooping: Bool = true
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.bookmarkData = bookmarkData
        self.isLooping = isLooping
    }
}
