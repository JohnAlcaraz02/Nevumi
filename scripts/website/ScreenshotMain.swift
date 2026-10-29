import AppKit
import SwiftUI

@main
struct WebsiteScreenshots {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await renderAll()
                exit(0)
            } catch {
                fputs("Screenshot rendering failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func capture<V: View>(_ name: String, width: CGFloat, height: CGFloat, view: V) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        host.frame = rect
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
        window.orderOut(nil)
        print("Rendered \(name)")
    }

    @MainActor static func sampleDocument() -> CGImage {
        let image = NSImage(size: NSSize(width: 480, height: 1050))
        image.lockFocus()
        NSColor(srgbRed: 0.98, green: 0.97, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 480, height: 1050).fill()
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor(srgbRed: 0.2, green: 0.16, blue: 0.3, alpha: 1)]
        ("A little more space." as NSString).draw(at: NSPoint(x: 34, y: 966), withAttributes: heading)
        for index in 0..<5 {
            let y = CGFloat(880 - index * 175)
            ("\(String(format: "%02d", index + 1))  A quieter kind of workflow" as NSString).draw(at: NSPoint(x: 34, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.darkGray])
            for line in 0..<5 {
                NSColor(srgbRed: 0.85, green: 0.82, blue: 0.9, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 34, y: y - CGFloat(25 + line * 15), width: line == 4 ? 245 : 405, height: 4), xRadius: 2, yRadius: 2).fill()
            }
        }
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    @MainActor static func renderAll() async throws {
        let spotify = SpotifyObserver()
        spotify.nowPlaying = .init(title: "Evening, Slowly", artist: "Sample track", isPlaying: true, duration: 196, artworkURL: nil)
        spotify.lastPosition = 84
        spotify.lastPositionDate = .now
        let lyrics = LyricsViewModel()
        lyrics.lines = [.init(time: 0, text: "A little space to just be."), .init(time: 20, text: "Let the evening in."), .init(time: 40, text: "And let the world slow down.")]
        lyrics.currentLine = lyrics.lines[1]
        let assistant = QuickAssistantViewModel(spotify: spotify, lyrics: lyrics)
        try await capture("assistant", width: 540, height: 390, view: QuickAssistantView(viewModel: assistant, onClose: {}, onHeightChange: { _ in }))
        assistant.showCalendarComposer()
        assistant.calendarEntryTitle = "Time for a walk"
        assistant.calendarEntryNotes = "A little break, away from the screen."
        assistant.calendarEntryStartDate = Date(timeIntervalSince1970: 1793264400)
        try await capture("calendar", width: 540, height: 318, view: QuickAssistantView(viewModel: assistant, onClose: {}, onHeightChange: { _ in }))
        assistant.closeCalendarComposer()
        let sampleURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Nevumi Icon.png")
        let iconURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("app-icon.png")
        let icon = NSImage(contentsOf: iconURL)!
        let sampleCG = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        try NSBitmapImageRep(cgImage: sampleCG).representation(using: .png, properties: [:])!.write(to: sampleURL)
        assistant.attachments = [.init(url: sampleURL, typeName: "PNG image", extractedText: "")]
        assistant.messages = [.init(role: .user, text: "What can I do with this image?"), .init(role: .assistant, text: "You can enhance it, remove its background, open the image editor, or convert it to another format.", context: [.init(label: "Nevumi Icon.png", systemImage: "paperclip")])]
        try await capture("file-tools", width: 540, height: 390, view: QuickAssistantView(viewModel: assistant, onClose: {}, onHeightChange: { _ in }))
        let conversion = NotchConvertCardModel()
        conversion.configure(files: [sampleURL])
        try await capture("convert", width: 380, height: 144, view: NotchConvertCardView(model: conversion, onClose: {}))
        try await capture("notch-drop", width: 340, height: 150, view: NotchFileDropExpandedView(fileName: "Nevumi Icon.png", action: .convert).padding(.top, 28).frame(width: 340, height: 150).background(.black).clipShape(RoundedRectangle(cornerRadius: 22)))
        let playback = NotchPlaybackState()
        playback.title = "Evening, Slowly"
        playback.artist = "Sample track"
        playback.isPlaying = true
        playback.duration = 196
        playback.currentLyric = "Let the evening in."
        try await capture("notch-player", width: 380, height: 230, view: NotchExpandedView(state: playback, spotify: spotify).padding(20).frame(width: 380, height: 230).background(.black).clipShape(RoundedRectangle(cornerRadius: 24)))
        try await capture("sleep-mode", width: 1280, height: 800, view: SleepOverlayView(spotify: spotify, lyrics: lyrics, onDismiss: {}))
        let editor = try QuickAssistantImageEditorModel(sourceURL: sampleURL)
        try await capture("image-editor", width: 1040, height: 720, view: QuickAssistantImageEditorView(model: editor, onClose: {}))
        let screenshot = LongScreenshotEditorModel(image: sampleDocument())
        screenshot.style = .twilight
        try await capture("long-screenshot", width: 1000, height: 700, view: LongScreenshotEditorView(model: screenshot, onDone: {}))
        let defaults = UserDefaults(suiteName: "com.nevumi.website-screenshot-fixtures")!
        defaults.set(false, forKey: "windowShortcutsEnabled")
        let shortcuts = WindowManagementController(defaults: defaults)
        try await capture("keyboard-shortcuts", width: 528, height: 710, view: WindowShortcutsSettingsView(controller: shortcuts).frame(width: 528, height: 710).background(Color(nsColor: .windowBackgroundColor)))
    }
}
