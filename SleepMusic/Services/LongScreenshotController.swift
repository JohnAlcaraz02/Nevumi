import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LongScreenshotController: NSObject {
    static let shared = LongScreenshotController()

    private var selectionPanels: [NSPanel] = []
    private var escapeMonitor: Any?
    private var selectionStart: CGPoint?
    private var progressPanel: NSPanel?
    private var progressPreview: NSImageView?
    private var progressInstruction: NSTextField?
    private var progressStatus: NSTextField?
    private var captureTask: Task<Void, Never>?
    private var shouldFinish = false
    private var shouldCancel = false

    private override init() {}

    func start() {
        guard captureTask == nil, selectionPanels.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showPermissionAlert()
            return
        }
        beginSelection()
    }

    func cancel() {
        if selectionPanels.isEmpty {
            cancelCapture()
        } else {
            finishSelection()
        }
    }

    private func beginSelection() {
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()

        selectionPanels = NSScreen.screens.map { screen in
            let panel = LongScreenshotSelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hasShadow = false

            let selectionView = LongScreenshotSelectionView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                screenFrame: screen.frame
            )
            selectionView.onDragBegan = { [weak self] point in
                self?.selectionStart = point
                self?.updateSelection(from: point, to: point)
            }
            selectionView.onDragChanged = { [weak self] point in
                guard let self, let start = self.selectionStart else { return }
                self.updateSelection(from: start, to: point)
            }
            selectionView.onDragEnded = { [weak self] point in
                self?.completeSelection(at: point)
            }
            panel.contentView = selectionView
            panel.orderFrontRegardless()
            return panel
        }
        selectionPanels.first?.makeKey()

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.finishSelection()
            return nil
        }
    }

    private func updateSelection(from start: CGPoint, to end: CGPoint) {
        let rect = normalizedRect(from: start, to: end)
        selectionPanels
            .compactMap { $0.contentView as? LongScreenshotSelectionView }
            .forEach { $0.selectionRect = rect }
    }

    private func completeSelection(at point: CGPoint) {
        guard let start = selectionStart else { return }
        let appKitRect = normalizedRect(from: start, to: point)
        guard appKitRect.width >= 60, appKitRect.height >= 60 else {
            selectionStart = nil
            updateSelection(from: .zero, to: .zero)
            return
        }

        let quartzRect = quartzRect(for: appKitRect)
        finishSelection()
        shouldCancel = false
        shouldFinish = false
        captureTask = Task {
            defer {
                captureTask = nil
                hideProgress()
            }
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch { return }
            guard !shouldCancel else { return }
            await prepareCapture(region: quartzRect)
        }
    }

    private func finishSelection() {
        guard !selectionPanels.isEmpty else { return }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        selectionPanels.forEach { $0.orderOut(nil) }
        selectionPanels.removeAll()
        selectionStart = nil
        NSCursor.pop()
    }

    private func prepareCapture(region requestedRegion: CGRect) async {
        do {
            let selectionPoint = CGPoint(x: requestedRegion.midX, y: requestedRegion.midY)
            guard let target = windowTarget(at: selectionPoint) else {
                throw LongScreenshotError.noWindow
            }

            let region = requestedRegion.intersection(target.frame)
            guard region.width >= 60, region.height >= 60 else {
                throw LongScreenshotError.regionTooSmall
            }

            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                throw LongScreenshotError.noWindow
            }

            guard !shouldCancel, !Task.isCancelled else { return }
            showProgress(beside: region)
            NSRunningApplication(processIdentifier: target.ownerPID)?.activate()
            try await Task.sleep(for: .milliseconds(180))
            if let result = try await captureWhileUserScrolls(window: window, region: region) {
                LongScreenshotEditorController.shared.show(image: result)
            }
        } catch is CancellationError {
            return
        } catch {
            showError(error)
        }
    }

    private func captureWhileUserScrolls(window: SCWindow, region: CGRect) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadows = true
        configuration.includeChildWindows = false
        configuration.dynamicRange = .sdr

        let first = try await screenshotRegion(
            window: window,
            region: region,
            filter: filter,
            configuration: configuration
        )
        guard first.width >= 60, first.height >= 60 else {
            throw LongScreenshotError.regionTooSmall
        }

        var frames = [first]
        var appendedHeights: [Int] = []
        var totalHeight = first.height
        let maximumOutputHeight = 30_000
        let maximumSections = 80
        updateProgress(frames: frames, appendedHeights: appendedHeights, totalHeight: totalHeight)

        while !shouldFinish, !shouldCancel,
              frames.count < maximumSections, totalHeight < maximumOutputHeight {
            try await Task.sleep(for: .milliseconds(220))
            guard !shouldFinish, !shouldCancel else { break }

            let next = try await screenshotRegion(
                window: window,
                region: region,
                filter: filter,
                configuration: configuration
            )
            guard next.width == first.width, next.height == first.height else {
                throw LongScreenshotError.windowResized
            }

            let previous = frames[frames.count - 1]
            let shift = await Task.detached(priority: .userInitiated) { () -> Int? in
                if LongScreenshotStitcher.imagesAreEquivalent(previous, next) { return 0 }
                return LongScreenshotStitcher.verticalShift(from: previous, to: next)
            }.value
            guard !shouldCancel else { return nil }
            if shift == 0 { continue }
            guard let shift else {
                progressInstruction?.stringValue = "Scroll a little slower so the sections overlap"
                continue
            }

            // Keep complete joins at the height limit. Cropping only the bottom
            // of an oversized final section would skip content at the seam.
            guard shift <= maximumOutputHeight - totalHeight else { break }
            let appendHeight = shift
            frames.append(next)
            appendedHeights.append(appendHeight)
            totalHeight += appendHeight
            updateProgress(frames: frames, appendedHeights: appendedHeights, totalHeight: totalHeight)
        }

        guard !shouldCancel else { return nil }
        progressInstruction?.stringValue = "Stitching screenshot…"
        if frames.count == 1 { return first }
        return try LongScreenshotStitcher.stitch(
            frames: frames,
            appendedHeights: appendedHeights,
            outputHeight: totalHeight
        )
    }

    private func screenshotRegion(
        window: SCWindow,
        region: CGRect,
        filter: SCContentFilter,
        configuration: SCScreenshotConfiguration
    ) async throws -> CGImage {
        let fullImage = try await screenshot(filter: filter, configuration: configuration)
        let scaleX = CGFloat(fullImage.width) / window.frame.width
        let scaleY = CGFloat(fullImage.height) / window.frame.height
        let localRegion = CGRect(
            x: (region.minX - window.frame.minX) * scaleX,
            y: (region.minY - window.frame.minY) * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        let cropRect = localRegion.intersection(imageBounds)

        guard cropRect.width >= 60, cropRect.height >= 60,
              let cropped = fullImage.cropping(to: cropRect) else {
            throw LongScreenshotError.regionTooSmall
        }
        return cropped
    }

    private func screenshot(
        filter: SCContentFilter,
        configuration: SCScreenshotConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureScreenshot(
                contentFilter: filter,
                configuration: configuration
            ) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image = output?.sdrImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: LongScreenshotError.captureFailed)
                }
            }
        }
    }

    private func windowTarget(at point: CGPoint) -> WindowTarget? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                ownerPID != ownPID,
                let number = window[kCGWindowNumber as String] as? UInt32,
                let boundsValue = window[kCGWindowBounds as String],
                let boundsDictionary = boundsValue as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width >= 120,
                bounds.height >= 120,
                bounds.contains(point)
            else { continue }

            return WindowTarget(
                windowID: CGWindowID(number),
                ownerPID: pid_t(ownerPID),
                frame: bounds
            )
        }
        return nil
    }

    private func showProgress(beside quartzRegion: CGRect) {
        let panelSize = NSSize(width: 276, height: 190)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let title = NSTextField(labelWithString: "Scrolling capture")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.layer?.cornerRadius = 7
        preview.translatesAutoresizingMaskIntoConstraints = false

        let instruction = NSTextField(labelWithString: "Scroll down through the content")
        instruction.font = .systemFont(ofSize: 11, weight: .medium)
        instruction.textColor = .secondaryLabelColor
        instruction.alignment = .center
        instruction.lineBreakMode = .byTruncatingTail
        instruction.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: "1 section")
        status.font = .systemFont(ofSize: 10)
        status.textColor = .tertiaryLabelColor
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelCapture))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let finishButton = NSButton(title: "Finish", target: self, action: #selector(finishCapture))
        finishButton.bezelStyle = .rounded
        finishButton.controlSize = .small
        finishButton.keyEquivalent = "\r"
        finishButton.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(origin: .zero, size: panelSize))
        [title, preview, instruction, status, cancelButton, finishButton].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            preview.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9),
            preview.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            preview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            preview.heightAnchor.constraint(equalToConstant: 78),
            instruction.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
            instruction.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            instruction.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            status.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 1),
            status.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            cancelButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            finishButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            finishButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
        panel.contentView = contentView

        let appKitRegion = appKitRect(fromQuartzRect: quartzRegion)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(appKitRegion) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? appKitRegion
        var x = appKitRegion.minX - panelSize.width - 12
        if x < visibleFrame.minX { x = appKitRegion.maxX + 12 }
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
        let y = min(
            max(appKitRegion.midY - panelSize.height / 2, visibleFrame.minY + 8),
            visibleFrame.maxY - panelSize.height - 8
        )
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        progressPanel = panel
        progressPreview = preview
        progressInstruction = instruction
        progressStatus = status
    }

    private func updateProgress(
        frames: [CGImage],
        appendedHeights: [Int],
        totalHeight: Int
    ) {
        progressInstruction?.stringValue = "Scroll down through the content"
        let sectionWord = frames.count == 1 ? "section" : "sections"
        progressStatus?.stringValue = "\(frames.count) \(sectionWord) • \(totalHeight) px"

        if let preview = LongScreenshotStitcher.preview(
            frames: frames,
            appendedHeights: appendedHeights,
            outputHeight: totalHeight,
            size: CGSize(width: 480, height: 150)
        ) {
            progressPreview?.image = NSImage(
                cgImage: preview,
                size: NSSize(width: preview.width, height: preview.height)
            )
        }
    }

    private func hideProgress() {
        progressPanel?.orderOut(nil)
        progressPanel = nil
        progressPreview = nil
        progressInstruction = nil
        progressStatus = nil
        shouldFinish = false
        shouldCancel = false
    }

    @objc private func finishCapture() {
        shouldFinish = true
        progressInstruction?.stringValue = "Stitching screenshot…"
    }

    @objc private func cancelCapture() {
        shouldCancel = true
        captureTask?.cancel()
        progressInstruction?.stringValue = "Cancelling…"
    }

    private func normalizedRect(from first: CGPoint, to second: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(first.x - second.x),
            height: abs(first.y - second.y)
        )
    }

    private func quartzRect(for appKitRect: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: appKitRect.minX,
            y: primaryHeight - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    private func appKitRect(fromQuartzRect rect: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording"
        alert.informativeText = "Long screenshots need Screen Recording access to capture the area you select. Enable Sleep Music in System Settings, then try again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t Make Long Screenshot"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private struct WindowTarget {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let frame: CGRect
    }
}

private final class LongScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class LongScreenshotSelectionView: NSView {
    let screenFrame: CGRect
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var selectionRect: CGRect = .zero { didSet { needsDisplay = true } }

    init(frame frameRect: NSRect, screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDragBegan?(globalPoint(for: event)) }
    override func mouseDragged(with event: NSEvent) { onDragChanged?(globalPoint(for: event)) }
    override func mouseUp(with event: NSEvent) { onDragEnded?(globalPoint(for: event)) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let localSelection = selectionRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let shade = NSBezierPath(rect: bounds)
        if !localSelection.isEmpty { shade.appendRect(localSelection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        shade.fill()

        if localSelection.width >= 1, localSelection.height >= 1 {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: localSelection)
            border.lineWidth = 2
            border.stroke()
            drawDimensionLabel(for: localSelection)
        } else {
            drawInstruction()
        }
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func drawInstruction() {
        let text = "Drag to select the scrolling area  •  Esc to cancel"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let card = NSRect(x: bounds.midX - 210, y: bounds.midY - 24, width: 420, height: 48)
        NSColor.black.withAlphaComponent(0.74).setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
        text.draw(
            in: NSRect(x: card.minX + 12, y: card.midY - 10, width: card.width - 24, height: 22),
            withAttributes: attributes
        )
    }

    private func drawDimensionLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        var origin = CGPoint(x: rect.midX - textSize.width / 2 - 7, y: rect.maxY + 7)
        if origin.y + textSize.height + 8 > bounds.maxY {
            origin.y = rect.maxY - textSize.height - 20
        }
        let labelRect = CGRect(
            x: origin.x,
            y: origin.y,
            width: textSize.width + 14,
            height: textSize.height + 8
        )
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: labelRect.minX + 7, y: labelRect.minY + 4), withAttributes: attributes)
    }
}

@MainActor
private final class LongScreenshotEditorController: NSObject {
    static let shared = LongScreenshotEditorController()
    private var window: NSWindow?

    func show(image: CGImage) {
        let model = LongScreenshotEditorModel(image: image)
        let rootView = LongScreenshotEditorView(
            model: model,
            onDone: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Long Screenshot Editor"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

@MainActor
private final class LongScreenshotEditorModel: ObservableObject {
    @Published var style: ScreenshotBackgroundStyle = .clean
    let image: CGImage

    init(image: CGImage) { self.image = image }

    func copy() {
        let rendered: CGImage
        do { rendered = try renderedImage() }
        catch {
            NSAlert(error: error).runModal()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([
            NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height)),
        ])
    }

    func save() {
        Task {
            do {
                let rendered = try renderedImage()
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let panel = NSSavePanel()
                panel.title = "Save Long Screenshot"
                panel.nameFieldStringValue = "Long Screenshot \(formatter.string(from: Date())).png"
                panel.allowedContentTypes = [.png]
                panel.canCreateDirectories = true
                guard await panel.begin() == .OK, let url = panel.url else { return }
                try writePNG(rendered, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func renderedImage() throws -> CGImage {
        let padding = 64
        let width = image.width + padding * 2
        let height = image.height + padding * 2
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw LongScreenshotError.captureFailed }

        let colors = style.colors.map(\.cgColor) as CFArray
        if style.colors.count > 1,
           let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: nil) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: height),
                end: CGPoint(x: width, y: 0),
                options: []
            )
        } else {
            context.setFillColor(style.colors[0].cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        let imageRect = CGRect(x: padding, y: padding, width: image.width, height: image.height)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        context.addPath(CGPath(roundedRect: imageRect, cornerWidth: 16, cornerHeight: 16, transform: nil))
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()
        guard let result = context.makeImage() else { throw LongScreenshotError.captureFailed }
        return result
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw LongScreenshotError.couldNotSave }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LongScreenshotError.couldNotSave }
    }
}

private struct LongScreenshotEditorView: View {
    @ObservedObject var model: LongScreenshotEditorModel
    let onDone: () -> Void
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Long Screenshot").font(.headline)
                Spacer()
                Button("Copy") { model.copy() }
                Button("Save As…") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider()

            HStack(spacing: 0) {
                ScrollView([.vertical, .horizontal]) {
                    screenshotCanvas
                        .padding(36)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Appearance").font(.system(size: 13, weight: .semibold))
                    Text("Background").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(ScreenshotBackgroundStyle.allCases) { style in
                            Button { model.style = style } label: {
                                VStack(spacing: 5) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(style.gradient)
                                        .frame(height: 42)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(
                                                    model.style == style ? Color.accentColor : Color.primary.opacity(0.12),
                                                    lineWidth: model.style == style ? 2 : 1
                                                )
                                        }
                                    Text(style.title).font(.caption2).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                }
                .padding(16)
                .frame(width: 210)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var screenshotCanvas: some View {
        Image(decorative: model.image, scale: 1)
            .resizable()
            .aspectRatio(CGFloat(model.image.width) / CGFloat(model.image.height), contentMode: .fit)
            .frame(width: min(650, CGFloat(model.image.width)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
            .padding(28)
            .background(model.style.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private enum ScreenshotBackgroundStyle: String, CaseIterable, Identifiable {
    case clean, dark, warm, minimal, paper, sage, slate, blush, twilight, ocean, sunset, forest

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colors: [NSColor] {
        switch self {
        case .clean: return [NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)]
        case .dark: return [NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)]
        case .warm: return [NSColor(srgbRed: 1, green: 0.73, blue: 0.48, alpha: 1)]
        case .minimal: return [.white]
        case .paper: return [NSColor(srgbRed: 0.97, green: 0.94, blue: 0.84, alpha: 1)]
        case .sage: return [NSColor(srgbRed: 0.72, green: 0.82, blue: 0.69, alpha: 1)]
        case .slate: return [NSColor(srgbRed: 0.16, green: 0.25, blue: 0.34, alpha: 1)]
        case .blush: return [NSColor(srgbRed: 0.96, green: 0.74, blue: 0.79, alpha: 1)]
        case .twilight:
            return [
                NSColor(srgbRed: 0.22, green: 0.29, blue: 0.90, alpha: 1),
                NSColor(srgbRed: 0.55, green: 0.22, blue: 0.77, alpha: 1),
            ]
        case .ocean:
            return [
                NSColor(srgbRed: 0.03, green: 0.48, blue: 0.76, alpha: 1),
                NSColor(srgbRed: 0.02, green: 0.72, blue: 0.72, alpha: 1),
            ]
        case .sunset:
            return [
                NSColor(srgbRed: 0.95, green: 0.32, blue: 0.34, alpha: 1),
                NSColor(srgbRed: 0.98, green: 0.65, blue: 0.27, alpha: 1),
            ]
        case .forest:
            return [
                NSColor(srgbRed: 0.08, green: 0.38, blue: 0.25, alpha: 1),
                NSColor(srgbRed: 0.28, green: 0.57, blue: 0.31, alpha: 1),
            ]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: colors.map(Color.init(nsColor:)),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private enum LongScreenshotError: LocalizedError {
    case noWindow
    case regionTooSmall
    case windowResized
    case captureFailed
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .noWindow: return "Select an area inside a normal app window."
        case .regionTooSmall: return "Drag a larger rectangle inside the scrolling content and try again."
        case .windowResized: return "The window changed size during capture. Keep it still and try again."
        case .captureFailed: return "macOS did not return an image for the selected area."
        case .couldNotSave: return "The stitched PNG could not be written to the selected location."
        }
    }
}

enum LongScreenshotStitcher {
    static func imagesAreEquivalent(_ first: CGImage, _ second: CGImage) -> Bool {
        guard let a = PixelBuffer(image: first), let b = PixelBuffer(image: second),
              a.width == b.width, a.height == b.height else { return false }
        var changed = 0
        var sampled = 0
        let xStep = max(4, a.width / 90)
        let yStep = max(4, a.height / 90)
        for y in stride(from: a.height / 8, to: a.height * 9 / 10, by: yStep) {
            for x in stride(from: a.width / 10, to: a.width * 9 / 10, by: xStep) {
                sampled += 1
                if a.difference(atX: x, y: y, from: b, otherY: y) > 18 { changed += 1 }
            }
        }
        return sampled > 0 && Double(changed) / Double(sampled) < 0.004
    }

    static func verticalShift(from previous: CGImage, to current: CGImage) -> Int? {
        guard let a = PixelBuffer(image: previous), let b = PixelBuffer(image: current),
              a.width == b.width, a.height == b.height else { return nil }
        let height = a.height
        let stationaryScore = overlapScore(a, b, shift: 0)
        guard stationaryScore > 0.8 else { return nil }
        var bestShift = 0
        var bestScore = Double.greatestFiniteMagnitude
        // Search every pixel: coarse sampling skips small scrolls and can lock
        // onto a repeated line much further down the page.
        for shift in 1...(height * 4 / 5) {
            let score = overlapScore(a, b, shift: shift)
            if score < bestScore { bestScore = score; bestShift = shift }
        }
        let localStationaryScore = overlapScore(a, b, shift: bestShift, unshifted: true)
        return bestScore < 12 && localStationaryScore > 0.8
            && bestScore < localStationaryScore * 0.6 ? bestShift : nil
    }

    static func stitch(frames: [CGImage], appendedHeights: [Int], outputHeight: Int) throws -> CGImage {
        guard let first = frames.first, frames.count == appendedHeights.count + 1 else {
            throw LongScreenshotError.captureFailed
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: first.width,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw LongScreenshotError.captureFailed }
        drawStitched(
            frames: frames,
            appendedHeights: appendedHeights,
            outputHeight: outputHeight,
            in: context,
            destination: CGRect(x: 0, y: 0, width: first.width, height: outputHeight)
        )
        guard let result = context.makeImage() else { throw LongScreenshotError.captureFailed }
        return result
    }

    static func preview(
        frames: [CGImage],
        appendedHeights: [Int],
        outputHeight: Int,
        size: CGSize
    ) -> CGImage? {
        guard let first = frames.first, frames.count == appendedHeights.count + 1 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let scale = min(size.width / CGFloat(first.width), size.height / CGFloat(outputHeight))
        let destination = CGRect(
            x: (size.width - CGFloat(first.width) * scale) / 2,
            y: (size.height - CGFloat(outputHeight) * scale) / 2,
            width: CGFloat(first.width) * scale,
            height: CGFloat(outputHeight) * scale
        )
        drawStitched(
            frames: frames,
            appendedHeights: appendedHeights,
            outputHeight: outputHeight,
            in: context,
            destination: destination
        )
        return context.makeImage()
    }

    private static func drawStitched(
        frames: [CGImage],
        appendedHeights: [Int],
        outputHeight: Int,
        in context: CGContext,
        destination: CGRect
    ) {
        guard let first = frames.first else { return }
        context.interpolationQuality = .high
        let scaleX = destination.width / CGFloat(first.width)
        let scaleY = destination.height / CGFloat(outputHeight)
        var cursorY = destination.maxY - CGFloat(first.height) * scaleY
        context.draw(
            first,
            in: CGRect(
                x: destination.minX,
                y: cursorY,
                width: CGFloat(first.width) * scaleX,
                height: CGFloat(first.height) * scaleY
            )
        )
        for (index, appendHeight) in appendedHeights.enumerated() {
            let frame = frames[index + 1]
            let cropRect = CGRect(
                x: 0,
                y: frame.height - appendHeight,
                width: frame.width,
                height: appendHeight
            )
            guard let slice = frame.cropping(to: cropRect) else { continue }
            cursorY -= CGFloat(appendHeight) * scaleY
            context.draw(
                slice,
                in: CGRect(
                    x: destination.minX,
                    y: cursorY,
                    width: CGFloat(frame.width) * scaleX,
                    height: CGFloat(appendHeight) * scaleY
                )
            )
        }
    }

    private static func overlapScore(
        _ a: PixelBuffer, _ b: PixelBuffer, shift: Int, unshifted: Bool = false
    ) -> Double {
        let overlap = a.height - shift
        guard overlap > 12 else { return .greatestFiniteMagnitude }
        let topSkip = min(a.height / 7, overlap / 4)
        let bottom = overlap - min(a.height / 30, overlap / 8)
        guard bottom > topSkip else { return .greatestFiniteMagnitude }
        let xStep = max(1, a.width / 32)
        let yStep = max(1, (bottom - topSkip) / 24)
        var difference = 0
        var samples = 0
        for y in stride(from: topSkip, to: bottom, by: yStep) {
            for x in stride(from: a.width / 10, to: a.width * 9 / 10, by: xStep) {
                difference += a.difference(atX: x, y: y + (unshifted ? 0 : shift), from: b, otherY: y)
                samples += 1
            }
        }
        guard samples > 0 else { return .greatestFiniteMagnitude }
        return Double(difference) / Double(samples)
    }

    private struct PixelBuffer {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(image: CGImage) {
            let imageWidth = image.width
            let imageHeight = image.height
            let bytesPerRow = imageWidth * 4
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                    data: nil,
                    width: imageWidth,
                    height: imageHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ), let data = context.data else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            width = imageWidth
            height = imageHeight
            bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                              count: bytesPerRow * imageHeight))
        }

        func difference(atX x: Int, y: Int, from other: PixelBuffer, otherY: Int) -> Int {
            let index = (y * width + x) * 4
            let otherIndex = (otherY * width + x) * 4
            return (
                abs(Int(bytes[index]) - Int(other.bytes[otherIndex]))
                + abs(Int(bytes[index + 1]) - Int(other.bytes[otherIndex + 1]))
                + abs(Int(bytes[index + 2]) - Int(other.bytes[otherIndex + 2]))
            ) / 3
        }
    }
}
