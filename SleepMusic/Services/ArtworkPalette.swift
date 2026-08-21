import AppKit
import CoreImage
import SwiftUI

/// Extracts a mood color from the currently playing track's artwork, so
/// Sleep Mode's background can shift to match whatever's playing instead of
/// staying a fixed palette — the "lit by the album art" feel of a real lock
/// screen Now Playing view.
@MainActor
final class ArtworkPalette: ObservableObject {
    @Published private(set) var accentColor: Color?

    private var lastURL: URL?

    func update(artworkURL: URL?) {
        guard artworkURL != lastURL else { return }
        lastURL = artworkURL
        guard let artworkURL else {
            accentColor = nil
            return
        }
        Task {
            let color = await Self.averageColor(at: artworkURL)
            guard lastURL == artworkURL else { return } // a newer track arrived first
            accentColor = color
        }
    }

    private static func averageColor(at url: URL) async -> Color? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff)
        else { return nil }

        let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: ciImage,
                kCIInputExtentKey: CIVector(cgRect: ciImage.extent),
            ]
        )
        guard let output = filter?.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Color(
            red: Double(bitmap[0]) / 255,
            green: Double(bitmap[1]) / 255,
            blue: Double(bitmap[2]) / 255
        )
    }
}

extension Color {
    /// Shifts hue while keeping saturation/brightness in a range that still
    /// reads well as a glowing background blob, even from washed-out artwork.
    func hueShifted(by amount: Double) -> Color {
        let nsColor = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        var shifted = (hue + amount).truncatingRemainder(dividingBy: 1)
        if shifted < 0 { shifted += 1 }

        return Color(
            hue: shifted,
            saturation: min(max(saturation, 0.45), 1),
            brightness: min(max(brightness, 0.4), 0.8)
        )
    }
}
