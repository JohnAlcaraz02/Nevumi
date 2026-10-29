import AppKit

/// Native AppKit sample documents for the website's focus-switching preview.
/// These are fixture windows, not screenshots of the user's desktop.
@main
struct WindowSwitchingImages {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try render(title: "Project Notes", heading: "A little more focus.", text: "A few ideas for the week ahead.\n\n• Refine the Nevumi website\n\n• Review the latest app build\n\n• Make room for a screen-free break", destination: folder.appendingPathComponent("window-notes.png"))
            try render(title: "Release Checklist", heading: "Ready when you are.", text: "The little things, in one place.\n\n✓ Update feature descriptions\n\n✓ Add the actual app interfaces\n\n○ Review the public download", destination: folder.appendingPathComponent("window-checklist.png"))
        }
    }

    @MainActor static func render(title: String, heading: String, text: String, destination: URL) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 345), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 345))
        let document = NSTextView(frame: scroll.bounds)
        document.isEditable = false
        document.textContainerInset = NSSize(width: 22, height: 26)
        document.backgroundColor = NSColor(srgbRed: 0.99, green: 0.985, blue: 1, alpha: 1)
        let content = NSMutableAttributedString(string: heading + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.labelColor])
        content.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        document.textStorage?.setAttributedString(content)
        scroll.documentView = document
        window.contentView = scroll
        guard let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
    }
}
