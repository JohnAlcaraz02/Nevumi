import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Owns the persisted list of imported tracks and the native file picker.
/// Only a security-scoped bookmark is stored — files stay wherever the
/// user put them on disk.
@MainActor
final class AudioLibraryService: ObservableObject {
    static let shared = AudioLibraryService()

    @Published private(set) var tracks: [AudioTrack] = []

    private let storageKey = "library.json"

    private init() {
        tracks = StorageService.shared.load([AudioTrack].self, from: storageKey) ?? []
    }

    func importTrack(category: AudioCategory, completion: @escaping (AudioTrack?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose an Audio File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.mp3, .wav, .aiff, .mpeg4Audio, .audio]

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            self?.addTrack(from: url, category: category, completion: completion)
        }
    }

    private func addTrack(from url: URL, category: AudioCategory, completion: @escaping (AudioTrack?) -> Void) {
        guard url.startAccessingSecurityScopedResource() else {
            completion(nil)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let track = AudioTrack(
                name: url.deletingPathExtension().lastPathComponent,
                category: category,
                bookmarkData: bookmark
            )
            tracks.append(track)
            persist()
            completion(track)
        } catch {
            print("AudioLibraryService: bookmark creation failed: \(error)")
            completion(nil)
        }
    }

    func removeTrack(_ track: AudioTrack) {
        tracks.removeAll { $0.id == track.id }
        persist()
    }

    /// Resolves a track's bookmark back into a usable URL. Returns nil if
    /// the underlying file has moved, been deleted, or is otherwise gone —
    /// callers should surface that as a "missing file" error, not crash.
    func resolvedURL(for track: AudioTrack) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: track.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return url
    }

    private func persist() {
        StorageService.shared.save(tracks, to: storageKey)
    }
}
