import AppKit
import CoreImage
import Foundation
import ImagePlayground
import UniformTypeIdentifiers
import Vision

/// Removes the background from an image entirely on-device using Apple's
/// Vision foreground instance masking. The result is written as a PNG whose
/// background pixels are fully transparent.
enum QuickAssistantBackgroundRemover {
    struct ReplacementColor: Sendable, Equatable {
        let displayName: String
        let filenameComponent: String
        let red: Double
        let green: Double
        let blue: Double

        fileprivate init(
            _ displayName: String,
            filenameComponent: String? = nil,
            red: Double,
            green: Double,
            blue: Double
        ) {
            self.displayName = displayName
            self.filenameComponent = filenameComponent ?? displayName.lowercased()
                .replacingOccurrences(of: " ", with: "-")
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    static func canProcess(_ type: UTType?) -> Bool {
        type?.conforms(to: .image) == true && type?.conforms(to: .pdf) != true
    }

    static func replacementColor(in request: String) -> ReplacementColor? {
        let command = request.lowercased()
        if let hex = firstMatch(in: command, pattern: #"#(?:[0-9a-f]{6}|[0-9a-f]{3})\b"#) {
            let digits = String(hex.dropFirst())
            let expanded = digits.count == 3
                ? digits.map { "\($0)\($0)" }.joined()
                : digits
            guard let value = UInt64(expanded, radix: 16) else { return nil }
            return ReplacementColor(
                "#" + expanded.uppercased(),
                filenameComponent: expanded.lowercased(),
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }

        let namedColors: [(aliases: [String], color: ReplacementColor)] = [
            (["light blue"], ReplacementColor("Light Blue", red: 0.678, green: 0.847, blue: 0.902)),
            (["dark blue", "navy blue", "navy"], ReplacementColor("Navy", red: 0.0, green: 0.122, blue: 0.247)),
            (["light green"], ReplacementColor("Light Green", red: 0.565, green: 0.933, blue: 0.565)),
            (["dark green"], ReplacementColor("Dark Green", red: 0.0, green: 0.392, blue: 0.0)),
            (["light gray", "light grey"], ReplacementColor("Light Gray", red: 0.827, green: 0.827, blue: 0.827)),
            (["dark gray", "dark grey"], ReplacementColor("Dark Gray", red: 0.25, green: 0.25, blue: 0.25)),
            (["red"], ReplacementColor("Red", red: 1.0, green: 0.231, blue: 0.188)),
            (["orange"], ReplacementColor("Orange", red: 1.0, green: 0.584, blue: 0.0)),
            (["yellow"], ReplacementColor("Yellow", red: 1.0, green: 0.8, blue: 0.0)),
            (["green"], ReplacementColor("Green", red: 0.204, green: 0.78, blue: 0.349)),
            (["mint"], ReplacementColor("Mint", red: 0.0, green: 0.78, blue: 0.745)),
            (["teal"], ReplacementColor("Teal", red: 0.0, green: 0.502, blue: 0.502)),
            (["cyan", "aqua"], ReplacementColor("Cyan", red: 0.196, green: 0.678, blue: 0.9)),
            (["blue"], ReplacementColor("Blue", red: 0.0, green: 0.478, blue: 1.0)),
            (["indigo"], ReplacementColor("Indigo", red: 0.345, green: 0.337, blue: 0.839)),
            (["purple", "violet"], ReplacementColor("Purple", red: 0.686, green: 0.322, blue: 0.87)),
            (["pink", "magenta"], ReplacementColor("Pink", red: 1.0, green: 0.176, blue: 0.333)),
            (["brown"], ReplacementColor("Brown", red: 0.635, green: 0.518, blue: 0.369)),
            (["beige", "cream"], ReplacementColor("Beige", red: 0.961, green: 0.961, blue: 0.863)),
            (["gray", "grey"], ReplacementColor("Gray", red: 0.557, green: 0.557, blue: 0.576)),
            (["black"], ReplacementColor("Black", red: 0.0, green: 0.0, blue: 0.0)),
            (["white"], ReplacementColor("White", red: 1.0, green: 1.0, blue: 1.0)),
        ]

        for entry in namedColors {
            for alias in entry.aliases {
                let escaped = NSRegularExpression.escapedPattern(for: alias)
                if firstMatch(
                    in: command,
                    pattern: "(?<![a-z0-9])\(escaped)(?![a-z0-9])"
                ) != nil {
                    return entry.color
                }
            }
        }
        return nil
    }

    static func replacementFilename(for source: URL, color: ReplacementColor) -> String {
        source.deletingPathExtension().lastPathComponent
            + "-" + color.filenameComponent + "-background.png"
    }

    static func generatedBackgroundFilename(for source: URL, prompt: String) -> String {
        let words = prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
        let description = words.isEmpty ? "generated" : words.joined(separator: "-")
        return source.deletingPathExtension().lastPathComponent
            + "-" + description + "-background.png"
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

    static func replaceBackground(
        from source: URL,
        destination: URL,
        color: ReplacementColor
    ) async throws -> URL {
        let hasSecurityAccess = source.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { source.stopAccessingSecurityScopedResource() }
        }

        guard let input = CIImage(
            contentsOf: source,
            options: [.applyOrientationProperty: true]
        ) else {
            throw RemovalError.unreadableImage
        }
        let inputExtent = input.extent.integral
        guard !inputExtent.isEmpty, !inputExtent.isInfinite else {
            throw RemovalError.unreadableImage
        }

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace,
              let sourceImage = context.createCGImage(
                input,
                from: inputExtent,
                format: .RGBA8,
                colorSpace: colorSpace
              ) else {
            throw RemovalError.unreadableImage
        }

        let mask = try await foregroundMask(for: sourceImage)
        let extent = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let background = CIImage(color: CIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
        )).cropped(to: extent)
        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw RemovalError.encodingFailed
        }
        blend.setValue(CIImage(cgImage: sourceImage), forKey: kCIInputImageKey)
        blend.setValue(background, forKey: kCIInputBackgroundImageKey)
        blend.setValue(CIImage(cgImage: mask), forKey: kCIInputMaskImageKey)
        guard let composited = blend.outputImage?.cropped(to: extent),
              let output = context.createCGImage(
                composited,
                from: extent,
                format: .RGBA8,
                colorSpace: colorSpace
              ),
              let data = NSBitmapImageRep(cgImage: output).representation(
                using: .png,
                properties: [:]
              ) else {
            throw RemovalError.encodingFailed
        }

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw RemovalError.writeFailed
        }
        return destination
    }

    static func replaceBackground(
        from source: URL,
        destination: URL,
        prompt: String
    ) async throws -> URL {
        let hasSecurityAccess = source.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { source.stopAccessingSecurityScopedResource() }
        }

        let sourceImage = try normalizedImage(from: source)
        let creator = try await ImageCreator()
        guard let style = creator.availableStyles.first else {
            throw RemovalError.generationUnavailable
        }
        let concept = ImagePlaygroundConcept.text(
            "A standalone background scene showing \(prompt). No people, characters, words, or foreground subjects."
        )
        var generatedBackground: CGImage?
        for try await generated in creator.images(
            for: [concept],
            style: style,
            limit: 1
        ) {
            generatedBackground = generated.cgImage
            break
        }
        guard let generatedBackground else {
            throw RemovalError.generationFailed
        }

        let mask = try await foregroundMask(for: sourceImage)
        let extent = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let unscaledBackground = CIImage(cgImage: generatedBackground)
        let scale = max(
            extent.width / unscaledBackground.extent.width,
            extent.height / unscaledBackground.extent.height
        )
        let scaledBackground = unscaledBackground.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let background = scaledBackground.transformed(by: CGAffineTransform(
            translationX: extent.midX - scaledBackground.extent.midX,
            y: extent.midY - scaledBackground.extent.midY
        )).cropped(to: extent)

        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw RemovalError.encodingFailed
        }
        blend.setValue(CIImage(cgImage: sourceImage), forKey: kCIInputImageKey)
        blend.setValue(background, forKey: kCIInputBackgroundImageKey)
        blend.setValue(CIImage(cgImage: mask), forKey: kCIInputMaskImageKey)

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace,
              let composited = blend.outputImage?.cropped(to: extent),
              let output = context.createCGImage(
                composited,
                from: extent,
                format: .RGBA8,
                colorSpace: colorSpace
              ),
              let data = NSBitmapImageRep(cgImage: output).representation(
                using: .png,
                properties: [:]
              ) else {
            throw RemovalError.encodingFailed
        }
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

    private static func normalizedImage(from source: URL) throws -> CGImage {
        guard let input = CIImage(
            contentsOf: source,
            options: [.applyOrientationProperty: true]
        ) else {
            throw RemovalError.unreadableImage
        }
        let extent = input.extent.integral
        guard !extent.isEmpty, !extent.isInfinite,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(
                input,
                from: extent,
                format: .RGBA8,
                colorSpace: colorSpace
              ) else {
            throw RemovalError.unreadableImage
        }
        return image
    }

    private static func firstMatch(in value: String, pattern: String) -> Substring? {
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return value[range]
    }

    enum RemovalError: LocalizedError {
        case unreadableImage
        case noSubjectFound
        case encodingFailed
        case writeFailed
        case generationUnavailable
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "The image could not be opened."
            case .noSubjectFound: return "No subject stood out enough from the background to cut out."
            case .encodingFailed: return "The cutout could not be encoded as a PNG."
            case .writeFailed: return "The cutout could not be saved."
            case .generationUnavailable: return "Background generation is not available on this Mac."
            case .generationFailed: return "No background image was generated."
            }
        }
    }
}
