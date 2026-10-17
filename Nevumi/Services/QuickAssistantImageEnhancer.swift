import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Applies a balanced, fully on-device photo enhancement while preserving the
/// source image's dimensions. The original file is never modified.
enum QuickAssistantImageEnhancer {
    static func canProcess(_ type: UTType?) -> Bool {
        type?.conforms(to: .image) == true && type?.conforms(to: .pdf) != true
    }

    static func preferredOutputType(for source: URL) -> UTType {
        switch source.pathExtension.lowercased() {
        case "png": return .png
        case "tif", "tiff": return .tiff
        default: return .jpeg
        }
    }

    static func enhancedFilename(for source: URL) -> String {
        let type = preferredOutputType(for: source)
        let fileExtension: String
        switch type {
        case .png: fileExtension = "png"
        case .tiff: fileExtension = "tiff"
        default: fileExtension = "jpg"
        }
        return source.deletingPathExtension().lastPathComponent + "-enhanced." + fileExtension
    }

    static func enhance(source: URL, destination: URL) throws -> URL {
        let hasSecurityAccess = source.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { source.stopAccessingSecurityScopedResource() }
        }

        guard var image = CIImage(
            contentsOf: source,
            options: [.applyOrientationProperty: true]
        ) else {
            throw EnhancementError.unreadableImage
        }

        let originalExtent = image.extent.integral
        guard !originalExtent.isEmpty, !originalExtent.isInfinite else {
            throw EnhancementError.unreadableImage
        }

        let automaticFilters = image.autoAdjustmentFilters(options: [
            .enhance: true,
            .redEye: true,
            .crop: false,
            .level: false,
        ])
        for filter in automaticFilters {
            filter.setValue(image, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                image = output
            }
        }

        // A light cleanup pass improves compressed or low-light photos without
        // producing the waxy texture common with aggressive noise reduction.
        image = applyingFilter(
            "CINoiseReduction",
            to: image,
            parameters: ["inputNoiseLevel": 0.015, "inputSharpness": 0.35]
        )
        image = applyingFilter(
            "CIUnsharpMask",
            to: image,
            parameters: [kCIInputRadiusKey: 1.25, kCIInputIntensityKey: 0.35]
        ).cropped(to: originalExtent)

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace,
              let output = context.createCGImage(
                image,
                from: originalExtent,
                format: .RGBA8,
                colorSpace: colorSpace
              ) else {
            throw EnhancementError.renderingFailed
        }

        let bitmap = NSBitmapImageRep(cgImage: output)
        let fileType: NSBitmapImageRep.FileType
        let properties: [NSBitmapImageRep.PropertyKey: Any]
        switch destination.pathExtension.lowercased() {
        case "jpg", "jpeg":
            fileType = .jpeg
            properties = [.compressionFactor: 0.94]
        case "png":
            fileType = .png
            properties = [:]
        case "tif", "tiff":
            fileType = .tiff
            properties = [
                .compressionMethod: NSNumber(
                    value: NSBitmapImageRep.TIFFCompression.lzw.rawValue
                ),
            ]
        default:
            throw EnhancementError.unsupportedOutputFormat
        }

        guard let data = bitmap.representation(using: fileType, properties: properties) else {
            throw EnhancementError.encodingFailed
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw EnhancementError.writeFailed
        }
        return destination
    }

    private static func applyingFilter(
        _ name: String,
        to image: CIImage,
        parameters: [String: Any]
    ) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        parameters.forEach { filter.setValue($0.value, forKey: $0.key) }
        return filter.outputImage ?? image
    }

    enum EnhancementError: LocalizedError {
        case unreadableImage
        case renderingFailed
        case unsupportedOutputFormat
        case encodingFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "The image could not be opened."
            case .renderingFailed: return "The enhanced image could not be rendered."
            case .unsupportedOutputFormat: return "Choose JPEG, PNG, or TIFF as the output format."
            case .encodingFailed: return "The enhanced image could not be encoded."
            case .writeFailed: return "The enhanced image could not be saved."
            }
        }
    }
}
