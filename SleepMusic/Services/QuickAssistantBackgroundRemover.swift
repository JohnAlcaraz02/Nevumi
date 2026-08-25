import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers
import Vision

/// Removes the background from an image entirely on-device using Apple's
/// Vision foreground instance masking. The result is written as a PNG whose
/// background pixels are fully transparent.
enum QuickAssistantBackgroundRemover {
    static func canProcess(_ type: UTType?) -> Bool {
        type?.conforms(to: .image) == true && type?.conforms(to: .pdf) != true
    }

    static func removeBackground(from source: URL, destination: URL) async throws -> URL {
        let hasSecurityAccess = source.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { source.stopAccessingSecurityScopedResource() }
        }

        guard let image = NSImage(contentsOf: source) else { throw RemovalError.unreadableImage }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        else { throw RemovalError.unreadableImage }

        let request = GenerateForegroundInstanceMaskRequest()
        guard let observation = try await request.perform(on: cgImage) else {
            throw RemovalError.noSubjectFound
        }
        let instances = observation.allInstances
        guard !instances.isEmpty else { throw RemovalError.noSubjectFound }

        let handler = ImageRequestHandler(cgImage)
        let maskedBuffer = try observation.generateMaskedImage(
            for: instances,
            imageFrom: handler,
            croppedToInstancesExtent: false
        )
        let maskedImage = CIImage(cvPixelBuffer: maskedBuffer)
        let context = CIContext()
        guard let outputImage = context.createCGImage(maskedImage, from: maskedImage.extent),
              let data = NSBitmapImageRep(cgImage: outputImage).representation(
                using: .png,
                properties: [:]
              )
        else { throw RemovalError.encodingFailed }

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw RemovalError.writeFailed
        }
        return destination
    }

    /// Returns a full-resolution grayscale mask where white pixels are
    /// foreground and black pixels are background. The editor uses this as a
    /// starting point that the user can refine with erase and restore brushes.
    static func foregroundMask(for image: CGImage) async throws -> CGImage {
        let request = GenerateForegroundInstanceMaskRequest()
        guard let observation = try await request.perform(on: image) else {
            throw RemovalError.noSubjectFound
        }
        let instances = observation.allInstances
        guard !instances.isEmpty else { throw RemovalError.noSubjectFound }

        let handler = ImageRequestHandler(image)
        let maskBuffer = try observation.generateScaledMask(
            for: instances,
            scaledToImageFrom: handler
        )
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let output = context.createCGImage(maskImage, from: maskImage.extent) else {
            throw RemovalError.encodingFailed
        }
        return output
    }

    enum RemovalError: LocalizedError {
        case unreadableImage
        case noSubjectFound
        case encodingFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "The image could not be opened."
            case .noSubjectFound: return "No subject stood out enough from the background to cut out."
            case .encodingFailed: return "The cutout could not be encoded as a PNG."
            case .writeFailed: return "The cutout could not be saved."
            }
        }
    }
}
