import Foundation

/// Thin JSON persistence to ~/Library/Application Support/SleepMusic.
/// No cloud, no network — every read/write is local disk only.
final class StorageService {
    static let shared = StorageService()

    private let appSupportURL: URL

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportURL = base.appendingPathComponent("SleepMusic", isDirectory: true)
        try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    }

    func url(for filename: String) -> URL {
        appSupportURL.appendingPathComponent(filename)
    }

    func save<T: Encodable>(_ value: T, to filename: String) {
        let fileURL = url(for: filename)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("StorageService: failed to save \(filename): \(error)")
        }
    }

    func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let fileURL = url(for: filename)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
