import AppKit

// Run with swiftc -module-cache-path /tmp/sleepmusic-swift-module-cache
// SleepMusic/Services/LongScreenshotController.swift
// Tests/LongScreenshotStitcherTests.swift -o /tmp/long-screenshot-tests
@main
struct LongScreenshotStitcherTests {
    static func image(width: Int = 320, height: Int = 600, offset: Int = 0,
                      blank: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where !blank {
                let row = y + offset
                var hash = UInt64(row * width + x + 1)
                hash = (hash ^ (hash >> 16)) &* 0x45d9f3b
                hash = (hash ^ (hash >> 16)) &* 0x45d9f3b
                hash ^= hash >> 16
                let value = UInt8(truncatingIfNeeded: hash)
                let i = (y * width + x) * 4
                bytes[i] = value
                bytes[i + 1] = UInt8(truncatingIfNeeded: hash >> 8)
                bytes[i + 2] = UInt8(truncatingIfNeeded: hash >> 16)
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    static func main() throws {
        let first = image()
        precondition(LongScreenshotStitcher.imagesAreEquivalent(first, first))
        for shift in [1, 5, 15, 101, 240, 480] {
            let next = image(offset: shift)
            let detected = LongScreenshotStitcher.verticalShift(from: first, to: next)
            precondition(detected == shift, "Expected shift \(shift), got \(String(describing: detected))")
            let stitched = try LongScreenshotStitcher.stitch(
                frames: [first, next], appendedHeights: [shift], outputHeight: 600 + shift)
            precondition(pixels(stitched) == pixels(image(height: 600 + shift)), "Incorrect join at \(shift)")
        }
        precondition(LongScreenshotStitcher.verticalShift(from: image(blank: true), to: image(blank: true)) == nil,
                     "Blank content must not create a scroll")
        precondition(LongScreenshotStitcher.verticalShift(from: image(offset: 120), to: first) == nil,
                     "Scrolling upward must not append content")
        let joined = try LongScreenshotStitcher.stitch(
            frames: [first, image(offset: 101), image(offset: 341)],
            appendedHeights: [101, 240], outputHeight: 941)
        precondition(pixels(joined) == pixels(image(height: 941)), "Multiple sections lost content")
        precondition(LongScreenshotStitcher.verticalShift(from: image(height: 60),
                                                         to: image(height: 60, offset: 5)) == 5)
        precondition(LongScreenshotStitcher.preview(frames: [first, image(offset: 101)],
                                                   appendedHeights: [101], outputHeight: 701,
                                                   size: CGSize(width: 480, height: 150)) != nil)
        print("Long screenshot stitching checks passed")
    }
}
