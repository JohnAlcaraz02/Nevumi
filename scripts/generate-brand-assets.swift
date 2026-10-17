// Regenerate Nevumi's native app and template assets: swift scripts/generate-brand-assets.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Nevumi/Assets.xcassets")
let fm = FileManager.default

// Vector tracing of the approved ribbon mark, in a 470 × 306 coordinate space.
func mark() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: 244))
    p.addLine(to: CGPoint(x: 0, y: 140))
    p.addCurve(to: CGPoint(x: 119, y: 0), control1: CGPoint(x: 0, y: 57), control2: CGPoint(x: 46, y: 0))
    p.addCurve(to: CGPoint(x: 300, y: 141), control1: CGPoint(x: 208, y: 0), control2: CGPoint(x: 246, y: 70))
    p.addCurve(to: CGPoint(x: 345, y: 159), control1: CGPoint(x: 315, y: 163), control2: CGPoint(x: 328, y: 170))
    p.addCurve(to: CGPoint(x: 414, y: 86), control1: CGPoint(x: 371, y: 146), control2: CGPoint(x: 376, y: 86))
    p.addCurve(to: CGPoint(x: 470, y: 139), control1: CGPoint(x: 446, y: 86), control2: CGPoint(x: 470, y: 106))
    p.addLine(to: CGPoint(x: 470, y: 201))
    p.addCurve(to: CGPoint(x: 364, y: 306), control1: CGPoint(x: 470, y: 269), control2: CGPoint(x: 435, y: 306))
    p.addCurve(to: CGPoint(x: 217, y: 210), control1: CGPoint(x: 299, y: 306), control2: CGPoint(x: 262, y: 276))
    p.addCurve(to: CGPoint(x: 164, y: 146), control1: CGPoint(x: 186, y: 164), control2: CGPoint(x: 179, y: 136))
    p.addCurve(to: CGPoint(x: 119, y: 198), control1: CGPoint(x: 134, y: 148), control2: CGPoint(x: 119, y: 173))
    p.addLine(to: CGPoint(x: 119, y: 244))
    p.addCurve(to: CGPoint(x: 59, y: 306), control1: CGPoint(x: 119, y: 284), control2: CGPoint(x: 97, y: 306))
    p.addCurve(to: CGPoint(x: 0, y: 244), control1: CGPoint(x: 20, y: 306), control2: CGPoint(x: 0, y: 284))
    p.closeSubpath()
    return p
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
func gradient(_ context: CGContext, colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
let iconDir = assets.appendingPathComponent("AppIcon.appiconset")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 52, y: 52, width: 920, height: 920), cornerWidth: 207, cornerHeight: 207, transform: nil)); ctx.clip()
    gradient(ctx, colors: [color(0.81, 0.73, 1), color(0.49, 0.43, 0.96), color(0.32, 0.26, 0.78)], from: CGPoint(x: 120, y: 52), to: CGPoint(x: 880, y: 972))
    ctx.translateBy(x: 180, y: 296); ctx.scaleBy(x: 664 / 470, y: 664 / 470)
    ctx.addPath(mark()); ctx.clip()
    gradient(ctx, colors: [color(1, 1, 1), color(0.88, 0.85, 1)], from: CGPoint(x: 120, y: 0), to: CGPoint(x: 320, y: 306))
    // The overlapping fold gives the ribbon depth without weakening its silhouette.
    let fold = CGMutablePath()
    fold.move(to: CGPoint(x: 0, y: 140))
    fold.addCurve(to: CGPoint(x: 165, y: 146), control1: CGPoint(x: 21, y: 54), control2: CGPoint(x: 97, y: 62))
    fold.addCurve(to: CGPoint(x: 470, y: 252), control1: CGPoint(x: 277, y: 166), control2: CGPoint(x: 304, y: 304))
    fold.addLine(to: CGPoint(x: 470, y: 340)); fold.addLine(to: CGPoint(x: 0, y: 340)); fold.closeSubpath()
    ctx.addPath(fold); ctx.clip()
    gradient(ctx, colors: [color(0.98, 0.97, 1), color(0.78, 0.74, 0.99)], from: CGPoint(x: 55, y: 120), to: CGPoint(x: 440, y: 300))
    try rep.representation(using: .png, properties: [:])!.write(to: iconDir.appendingPathComponent("AppIcon-\(size).png"))
}
let markDir = assets.appendingPathComponent("NevumiMark.imageset")
try fm.createDirectory(at: markDir, withIntermediateDirectories: true)
var box = CGRect(x: 0, y: 0, width: 22, height: 15)
let pdf = CGContext(markDir.appendingPathComponent("NevumiMark.pdf") as CFURL, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
pdf.translateBy(x: 0, y: 14.66); pdf.scaleBy(x: 22 / 470, y: -22 / 470)
pdf.setFillColor(CGColor(gray: 0, alpha: 1)); pdf.addPath(mark()); pdf.fillPath()
pdf.endPDFPage(); pdf.closePDF()
try """
{"images":[{"filename":"NevumiMark.pdf","idiom":"universal"}],"info":{"author":"xcode","version":1},"properties":{"preserves-vector-representation":true,"template-rendering-intent":"template"}}
""".write(to: markDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Generated Nevumi app icons and vector template mark.")
