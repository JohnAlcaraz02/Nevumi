import AppKit
import CoreText
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AssistantConversionFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case tiff
    case pdf
    case plainText
    case wav
    case aiff
    case caf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .pdf: return "PDF"
        case .plainText: return "Text"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .caf: return "CAF"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .plainText: return "txt"
        default: return rawValue
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .pdf: return .pdf
        case .plainText: return .plainText
        case .wav: return .wav
        case .aiff: return .aiff
        case .caf: return UTType(filenameExtension: "caf") ?? .audio
        }
    }

    var isImage: Bool { self == .png || self == .jpeg || self == .tiff }
    var isAudio: Bool { self == .wav || self == .aiff || self == .caf }
}

enum QuickAssistantFileConverter {
    struct BatchInput {
        let source: URL
        let extractedText: String
    }

    static func availableFormats(for source: URL) -> [AssistantConversionFormat] {
        guard let type = detectedContentType(for: source) else { return [] }
        if type.conforms(to: .image) { return [.png, .jpeg, .tiff, .pdf] }
        if type.conforms(to: .pdf) { return [.png, .jpeg, .tiff, .plainText] }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return [.pdf] }
        if type.conforms(to: .audio) { return [.wav, .aiff, .caf] }
        return []
    }

    static func needsDestinationFolder(source: URL, format: AssistantConversionFormat) -> Bool {
        detectedContentType(for: source)?.conforms(to: .pdf) == true && format.isImage
    }

    static func convert(
        source: URL,
        extractedText: String,
        to format: AssistantConversionFormat,
        destination: URL
    ) throws -> [URL] {
        let hasSecurityAccess = source.startAccessingSecurityScopedResource()
        defer { if hasSecurityAccess { source.stopAccessingSecurityScopedResource() } }

        guard let type = detectedContentType(for: source) else { throw ConversionError.unsupportedInput }
        if type.conforms(to: .image) {
            return [try convertImage(source, to: format, destination: destination)]
        }
        if type.conforms(to: .pdf) {
            if format == .plainText {
                guard !extractedText.isEmpty else { throw ConversionError.noText }
                try Data(extractedText.utf8).write(to: destination, options: .atomic)
                return [destination]
            }
            guard format.isImage else { throw ConversionError.unsupportedOutput }
            return try convertPDFToImages(source, format: format, folder: destination)
        }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) {
            guard format == .pdf else { throw ConversionError.unsupportedOutput }
            guard !extractedText.isEmpty else { throw ConversionError.noText }
            try writeTextPDF(extractedText, to: destination)
            return [destination]
        }
        if type.conforms(to: .audio) {
            guard format.isAudio else { throw ConversionError.unsupportedOutput }
            return [try convertAudio(source, to: format, destination: destination)]
        }
        throw ConversionError.unsupportedInput
    }

    /// Converts every input into a user-selected folder. PDFs that produce
    /// multiple page images receive their own subfolder to keep batches tidy.
    static func convertBatch(
        _ inputs: [BatchInput],
        to format: AssistantConversionFormat,
        folder: URL
    ) throws -> [URL] {
        var outputs: [URL] = []

        for input in inputs {
            let available = availableFormats(for: input.source)
            guard available.contains(format) else { throw ConversionError.unsupportedOutput }

            let destination: URL
            if needsDestinationFolder(source: input.source, format: format) {
                let proposedFolder = folder.appendingPathComponent(
                    input.source.deletingPathExtension().lastPathComponent + "-pages"
                )
                destination = uniqueDirectory(for: proposedFolder)
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
            } else {
                let proposed = folder
                    .appendingPathComponent(input.source.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension(format.fileExtension)
                destination = uniqueURL(for: proposed)
            }

            outputs.append(contentsOf: try convert(
                source: input.source,
                extractedText: input.extractedText,
                to: format,
                destination: destination
            ))
        }

        return outputs
    }

    private static func convertImage(
        _ source: URL,
        to format: AssistantConversionFormat,
        destination: URL
    ) throws -> URL {
        guard let image = NSImage(contentsOf: source) else { throw ConversionError.unreadableImage }
        if format == .pdf {
            guard let page = PDFPage(image: image) else { throw ConversionError.encodingFailed }
            let document = PDFDocument()
            document.insert(page, at: 0)
            guard document.write(to: destination) else { throw ConversionError.writeFailed }
            return destination
        }

        guard format.isImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(
                using: bitmapType(for: format),
                properties: imageProperties(for: format)
              )
        else { throw ConversionError.encodingFailed }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func convertPDFToImages(
        _ source: URL,
        format: AssistantConversionFormat,
        folder: URL
    ) throws -> [URL] {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw ConversionError.unreadablePDF
        }
        let baseName = source.deletingPathExtension().lastPathComponent
        var outputs: [URL] = []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let targetWidth: CGFloat = 2_400
            let scale = targetWidth / max(bounds.width, 1)
            let image = page.thumbnail(
                of: NSSize(width: targetWidth, height: max(bounds.height * scale, 1)),
                for: .mediaBox
            )
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let data = bitmap.representation(
                    using: bitmapType(for: format),
                    properties: imageProperties(for: format)
                  )
            else { throw ConversionError.encodingFailed }

            let proposed = folder
                .appendingPathComponent(String(format: "%@-page-%03d", baseName, index + 1))
                .appendingPathExtension(format.fileExtension)
            let output = uniqueURL(for: proposed)
            try data.write(to: output, options: .atomic)
            outputs.append(output)
        }
        return outputs
    }

    private static func writeTextPDF(_ text: String, to destination: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw ConversionError.writeFailed }

        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let contentRect = mediaBox.insetBy(dx: 54, dy: 54)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                CGPath(rect: contentRect, transform: nil),
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard visible.length > 0 else { break }
            location += visible.length
        } while location < attributed.length
        context.closePDF()
    }

    /// Uses macOS's built-in Core Audio converter. This keeps conversion
    /// entirely local and supports compressed inputs such as MP3 and FLAC
    /// without bundling a third-party codec.
    private static func convertAudio(
        _ source: URL,
        to format: AssistantConversionFormat,
        destination: URL
    ) throws -> URL {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw ConversionError.sourceAndDestinationMatch
        }

        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }

        try runCoreAudioConversion(source: source, destination: temporary, format: format)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw ConversionError.writeFailed
        }
        return destination
    }

    private static func runCoreAudioConversion(
        source: URL,
        destination: URL,
        format: AssistantConversionFormat
    ) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [source.path, "-o", destination.path] + audioArguments(for: format)
        process.standardOutput = Pipe()
        process.standardError = errors

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ConversionError.audioEncodingFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionError.audioEncodingFailed(
                detail?.isEmpty == false ? detail! : "Core Audio could not encode this file."
            )
        }
    }

    private static func audioArguments(for format: AssistantConversionFormat) -> [String] {
        switch format {
        case .wav:
            return ["-f", "WAVE", "-d", "LEI16"]
        case .aiff:
            return ["-f", "AIFF", "-d", "BEI16"]
        case .caf:
            return ["-f", "caff", "-d", "LEI16"]
        default:
            return []
        }
    }

    static func detectedContentType(for url: URL) -> UTType? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"].contains(ext) {
            return .image
        }
        if ["mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "caf", "flac"].contains(ext) {
            return .audio
        }
        if [
            "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml",
            "xml", "html", "htm", "css", "log", "ini", "cfg", "conf", "toml", "sql",
        ].contains(ext) {
            return .text
        }
        if [
            "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts",
            "js", "jsx", "ts", "tsx", "py", "rb", "php", "go", "rs", "sh", "zsh", "bash",
            "fish", "pl", "lua", "r", "scala", "dart", "vue", "svelte",
        ].contains(ext) {
            return .text
        }

        return (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: ext)
    }

    private static func bitmapType(for format: AssistantConversionFormat) -> NSBitmapImageRep.FileType {
        switch format {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        default: return .png
        }
    }

    private static func imageProperties(for format: AssistantConversionFormat) -> [NSBitmapImageRep.PropertyKey: Any] {
        format == .jpeg ? [.compressionFactor: 0.9] : [:]
    }

    private static func uniqueURL(for proposed: URL) -> URL {
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

    private static func uniqueDirectory(for proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let parent = proposed.deletingLastPathComponent()
        let name = proposed.lastPathComponent
        for suffix in 2...999 {
            let candidate = parent.appendingPathComponent("\(name)-\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return proposed
    }

    private enum ConversionError: LocalizedError {
        case unsupportedInput, unsupportedOutput, unreadableImage, unreadablePDF
        case noText, encodingFailed, writeFailed, sourceAndDestinationMatch
        case audioEncodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedInput: return "That input file type is not supported for conversion."
            case .unsupportedOutput: return "That output format is not available for this file."
            case .unreadableImage: return "The image could not be opened."
            case .unreadablePDF: return "The PDF could not be opened."
            case .noText: return "No readable text is available to convert."
            case .encodingFailed: return "The output file could not be encoded."
            case .writeFailed: return "The converted file could not be written."
            case .sourceAndDestinationMatch: return "Choose a different destination so the original audio file stays untouched."
            case let .audioEncodingFailed(detail): return "Audio conversion failed. \(detail)"
            }
        }
    }
}
