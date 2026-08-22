import Foundation

/// File-system work performed after conversion. These actions only operate on
/// newly converted outputs; original attachments are never modified.
enum QuickAssistantOutputActions {
    static func compress(_ urls: [URL], to destination: URL) throws -> URL {
        guard !urls.isEmpty else { throw OutputActionError.noOutputs }

        let fileManager = FileManager.default
        let stagingFolder = fileManager.temporaryDirectory
            .appendingPathComponent("SleepMusic-Archive-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingFolder) }

        for source in urls {
            let hasAccess = source.startAccessingSecurityScopedResource()
            defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }

            let proposed = stagingFolder.appendingPathComponent(source.lastPathComponent)
            try fileManager.copyItem(at: source, to: uniqueURL(for: proposed))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc",
            stagingFolder.path,
            destination.path,
        ]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: destination.path) else {
            throw OutputActionError.compressionFailed
        }
        return destination
    }

    static func automaticArchiveURL(for urls: [URL]) -> URL {
        let first = urls[0]
        let folder = first.deletingLastPathComponent()
        let baseName = urls.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : "Converted Files"
        return uniqueURL(for: folder.appendingPathComponent(baseName).appendingPathExtension("zip"))
    }

    static func uniqueURL(for proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let folder = proposed.deletingLastPathComponent()
        let base = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        for suffix in 2...999 {
            let candidate = folder
                .appendingPathComponent("\(base)-\(suffix)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return proposed
    }

    enum OutputActionError: LocalizedError {
        case noOutputs
        case compressionFailed
        case destinationExists

        var errorDescription: String? {
            switch self {
            case .noOutputs: return "There are no converted files to process."
            case .compressionFailed: return "The ZIP archive could not be created."
            case .destinationExists: return "A file already exists at that destination."
            }
        }
    }
}
