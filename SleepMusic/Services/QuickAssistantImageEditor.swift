import AppKit
import CoreImage
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class QuickAssistantImageEditorModel: ObservableObject {
    enum BrushTool: String, CaseIterable, Identifiable {
        case erase
        case restore

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .erase: return "eraser.fill"
            case .restore: return "paintbrush.pointed.fill"
            }
        }
    }

    enum BackgroundStyle: String, CaseIterable, Identifiable {
        case transparent
        case white
        case black
        case color
        case photo
        case blurred

        var id: String { rawValue }
        var title: String {
            switch self {
            case .transparent: return "Transparent"
            case .white: return "White"
            case .black: return "Black"
            case .color: return "Color"
            case .photo: return "Photo"
            case .blurred: return "Blurred"
            }
        }
    }

    @Published private(set) var previewImage: NSImage?
    @Published var brushTool: BrushTool = .erase
    @Published var brushSize: CGFloat = 54
    @Published private(set) var backgroundStyle: BackgroundStyle = .transparent
    @Published private(set) var backgroundColor: Color = .indigo
    @Published private(set) var backgroundPhotoName: String?
    @Published private(set) var isProcessing = false
    @Published private(set) var statusMessage = "Brush over anything you want to remove."
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let sourceURL: URL
    let pixelSize: CGSize
    var onSaved: ((URL) -> Void)?

    private let originalImage: CGImage
    private var backgroundPhoto: CGImage?
    private let maskContext: CGContext
    private let renderContext = CIContext(options: [.cacheIntermediates: false])
    private var undoStack: [CGImage] = []
    private var redoStack: [CGImage] = []
    private var maskHasEdits = false
    private var strokeIsActive = false
    private var previousStrokePoint: CGPoint?
    private var lastPreviewTime: TimeInterval = 0

    init(sourceURL: URL) throws {
        self.sourceURL = sourceURL
        originalImage = try Self.loadNormalizedImage(from: sourceURL)
        pixelSize = CGSize(width: originalImage.width, height: originalImage.height)
        guard let context = Self.makeMaskContext(
            width: originalImage.width,
            height: originalImage.height
        ) else {
            throw EditorError.couldNotCreateMask
        }
        maskContext = context
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.fill(CGRect(origin: .zero, size: pixelSize))
        refreshPreview(force: true)
    }

    var aspectRatio: CGFloat {
        pixelSize.width / max(pixelSize.height, 1)
    }

    func setBackgroundStyle(_ style: BackgroundStyle) {
        backgroundStyle = style
        if style == .photo, backgroundPhoto == nil {
            statusMessage = "Choose a second image to use as the new background."
        }
        refreshPreview(force: true)
    }

    func setBackgroundColor(_ color: Color) {
        backgroundColor = color
        backgroundStyle = .color
        refreshPreview(force: true)
    }

    func chooseBackgroundPhoto() {
        guard !isProcessing else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Background Image"
        panel.prompt = "Use as Background"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            backgroundPhoto = try Self.loadNormalizedImage(from: source)
            backgroundPhotoName = source.lastPathComponent
            backgroundStyle = .photo
            refreshPreview(force: true)
            if maskHasEdits {
                statusMessage = "Using \(source.lastPathComponent) as the background."
            } else {
                removeBackgroundAutomatically()
            }
        } catch {
            statusMessage = "Couldn’t use that background image. " + error.localizedDescription
        }
    }

    func beginStroke() {
        strokeIsActive = false
        previousStrokePoint = nil
    }

    func paint(at location: CGPoint, canvasSize: CGSize) {
        guard !isProcessing,
              let mapped = imagePoint(for: location, canvasSize: canvasSize)
        else {
            previousStrokePoint = nil
            return
        }

        if !strokeIsActive {
            registerUndo()
            maskHasEdits = true
            strokeIsActive = true
        }

        let shade: CGFloat = brushTool == .erase ? 0 : 1
        let diameter = max(1, brushSize / mapped.displayScale)
        maskContext.saveGState()
        maskContext.setBlendMode(.copy)
        maskContext.setLineCap(.round)
        maskContext.setLineJoin(.round)
        maskContext.setLineWidth(diameter)
        maskContext.setStrokeColor(gray: shade, alpha: 1)
        maskContext.setFillColor(gray: shade, alpha: 1)

        if let previousStrokePoint {
            maskContext.move(to: previousStrokePoint)
            maskContext.addLine(to: mapped.point)
            maskContext.strokePath()
        } else {
            maskContext.fillEllipse(in: CGRect(
                x: mapped.point.x - diameter / 2,
                y: mapped.point.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }
        maskContext.restoreGState()
        previousStrokePoint = mapped.point
        refreshPreview(force: false)
    }

    func endStroke() {
        guard strokeIsActive else { return }
        strokeIsActive = false
        previousStrokePoint = nil
        statusMessage = brushTool == .erase
            ? "Removed the brushed area. Use Restore to refine the edge."
            : "Restored the brushed area."
        refreshPreview(force: true)
    }

    func removeBackgroundAutomatically() {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = "Finding the foreground on this Mac…"
        let image = originalImage

        Task { [weak self] in
            guard let self else { return }
            do {
                let foregroundMask = try await Task.detached(priority: .userInitiated) {
                    try await QuickAssistantBackgroundRemover.foregroundMask(for: image)
                }.value
                registerUndo()
                replaceMask(with: foregroundMask)
                maskHasEdits = true
                statusMessage = "Background removed. Refine it with Erase or Restore."
            } catch {
                statusMessage = "Couldn’t isolate the foreground. " + error.localizedDescription
            }
            isProcessing = false
            refreshPreview(force: true)
        }
    }

    func resetMask() {
        registerUndo()
        maskContext.saveGState()
        maskContext.setBlendMode(.copy)
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.fill(CGRect(origin: .zero, size: pixelSize))
        maskContext.restoreGState()
        maskHasEdits = false
        statusMessage = "Restored the original image."
        refreshPreview(force: true)
    }

    func undo() {
        guard let previous = undoStack.popLast(),
              let current = maskContext.makeImage() else { return }
        redoStack.append(current)
        replaceMask(with: previous)
        statusMessage = "Undid the last edit."
        updateHistoryState()
        refreshPreview(force: true)
    }

    func redo() {
        guard let next = redoStack.popLast(),
              let current = maskContext.makeImage() else { return }
        undoStack.append(current)
        replaceMask(with: next)
        statusMessage = "Redid the edit."
        updateHistoryState()
        refreshPreview(force: true)
    }

    func save() {
        guard !isProcessing else { return }
        let panel = NSSavePanel()
        panel.title = "Save Edited Image"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.canCreateDirectories = true
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.nameFieldStringValue = sourceURL
            .deletingPathExtension()
            .lastPathComponent + "-edited.png"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isProcessing = true
        statusMessage = "Saving the edited image…"
        do {
            try export(to: destination)
            statusMessage = "Saved " + destination.lastPathComponent + "."
            onSaved?(destination)
        } catch {
            statusMessage = "Couldn’t save the edit. " + error.localizedDescription
        }
        isProcessing = false
    }

    private func registerUndo() {
        guard let snapshot = maskContext.makeImage() else { return }
        undoStack.append(snapshot)
        if undoStack.count > 12 {
            undoStack.removeFirst(undoStack.count - 12)
        }
        redoStack.removeAll()
        updateHistoryState()
    }

    private func replaceMask(with image: CGImage) {
        maskContext.saveGState()
        maskContext.setBlendMode(.copy)
        maskContext.interpolationQuality = .high
        maskContext.draw(image, in: CGRect(origin: .zero, size: pixelSize))
        maskContext.restoreGState()
        updateHistoryState()
    }

    private func updateHistoryState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func imagePoint(
        for location: CGPoint,
        canvasSize: CGSize
    ) -> (point: CGPoint, displayScale: CGFloat)? {
        let scale = min(
            canvasSize.width / pixelSize.width,
            canvasSize.height / pixelSize.height
        )
        guard scale.isFinite, scale > 0 else { return nil }
        let fittedSize = CGSize(
            width: pixelSize.width * scale,
            height: pixelSize.height * scale
        )
        let fittedRect = CGRect(
            x: (canvasSize.width - fittedSize.width) / 2,
            y: (canvasSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
        guard fittedRect.contains(location) else { return nil }
        return (
            CGPoint(
                x: (location.x - fittedRect.minX) / scale,
                y: (fittedRect.maxY - location.y) / scale
            ),
            scale
        )
    }

    private func refreshPreview(force: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        guard force || now - lastPreviewTime >= 1.0 / 30.0 else { return }
        lastPreviewTime = now
        guard let mask = maskContext.makeImage(),
              let preview = renderedImage(mask: mask, maximumDimension: 1_200)
        else { return }
        previewImage = NSImage(
            cgImage: preview,
            size: NSSize(width: preview.width, height: preview.height)
        )
    }

    private func renderedImage(
        mask: CGImage,
        maximumDimension: CGFloat? = nil,
        flattenTransparency: Bool = false
    ) -> CGImage? {
        let extent = CGRect(origin: .zero, size: pixelSize)
        let foreground = CIImage(cgImage: originalImage)
        let maskImage = CIImage(cgImage: mask)
        let background = backgroundImage(
            extent: extent,
            flattenTransparency: flattenTransparency
        )
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(foreground, forKey: kCIInputImageKey)
        blend.setValue(background, forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskImage, forKey: kCIInputMaskImageKey)
        guard var output = blend.outputImage?.cropped(to: extent) else { return nil }

        var outputRect = extent
        if let maximumDimension {
            let scale = min(1, maximumDimension / max(pixelSize.width, pixelSize.height))
            if scale < 1 {
                output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                outputRect = CGRect(
                    x: 0,
                    y: 0,
                    width: floor(pixelSize.width * scale),
                    height: floor(pixelSize.height * scale)
                )
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return renderContext.createCGImage(
            output,
            from: outputRect,
            format: .RGBA8,
            colorSpace: colorSpace
        )
    }

    private func backgroundImage(
        extent: CGRect,
        flattenTransparency: Bool
    ) -> CIImage {
        let color: CIColor
        switch backgroundStyle {
        case .transparent where !flattenTransparency:
            color = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        case .transparent, .white:
            color = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .black:
            color = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        case .color:
            let nsColor = NSColor(backgroundColor).usingColorSpace(.sRGB) ?? .white
            color = CIColor(
                red: nsColor.redComponent,
                green: nsColor.greenComponent,
                blue: nsColor.blueComponent,
                alpha: 1
            )
        case .photo:
            guard let backgroundPhoto else {
                return CIImage(color: .white).cropped(to: extent)
            }
            let image = CIImage(cgImage: backgroundPhoto)
            let scale = max(
                extent.width / image.extent.width,
                extent.height / image.extent.height
            )
            let scaled = image.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )
            let translation = CGAffineTransform(
                translationX: extent.midX - scaled.extent.midX,
                y: extent.midY - scaled.extent.midY
            )
            return scaled.transformed(by: translation).cropped(to: extent)
        case .blurred:
            let radius = max(pixelSize.width, pixelSize.height) * 0.025
            return CIImage(cgImage: originalImage)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        }
        return CIImage(color: color).cropped(to: extent)
    }

    private func export(to destination: URL) throws {
        guard let mask = maskContext.makeImage() else {
            throw EditorError.couldNotCreateMask
        }
        let fileExtension = destination.pathExtension.lowercased()
        let flattenTransparency = fileExtension == "jpg" || fileExtension == "jpeg"
        guard let image = renderedImage(
            mask: mask,
            flattenTransparency: flattenTransparency
        ) else {
            throw EditorError.renderingFailed
        }

        let representation = NSBitmapImageRep(cgImage: image)
        let fileType: NSBitmapImageRep.FileType
        let properties: [NSBitmapImageRep.PropertyKey: Any]
        switch fileExtension {
        case "png":
            fileType = .png
            properties = [:]
        case "jpg", "jpeg":
            fileType = .jpeg
            properties = [.compressionFactor: 0.94]
        case "tif", "tiff":
            fileType = .tiff
            properties = [
                .compressionMethod: NSNumber(
                    value: NSBitmapImageRep.TIFFCompression.lzw.rawValue
                ),
            ]
        default:
            throw EditorError.unsupportedFormat
        }
        guard let data = representation.representation(
            using: fileType,
            properties: properties
        ) else {
            throw EditorError.encodingFailed
        }
        try data.write(to: destination, options: .atomic)
    }

    private static func loadNormalizedImage(from source: URL) throws -> CGImage {
        let hasSecurityAccess = source.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { source.stopAccessingSecurityScopedResource() }
        }
        guard let input = CIImage(
            contentsOf: source,
            options: [.applyOrientationProperty: true]
        ) else {
            throw EditorError.unreadableImage
        }
        let extent = input.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else {
            throw EditorError.unreadableImage
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let output = context.createCGImage(
            input,
            from: extent,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw EditorError.unreadableImage
        }
        return output
    }

    private static func makeMaskContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }

    enum EditorError: LocalizedError {
        case unreadableImage
        case couldNotCreateMask
        case renderingFailed
        case unsupportedFormat
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "The image could not be opened."
            case .couldNotCreateMask: return "The editable image mask could not be created."
            case .renderingFailed: return "The edited image could not be rendered."
            case .unsupportedFormat: return "Save the edit as PNG, JPEG, or TIFF."
            case .encodingFailed: return "The edited image could not be encoded."
            }
        }
    }
}

@MainActor
final class QuickAssistantImageEditorController: NSObject, NSWindowDelegate {
    static let shared = QuickAssistantImageEditorController()

    private var window: NSWindow?
    private var model: QuickAssistantImageEditorModel?

    func present(source: URL, onSaved: @escaping (URL) -> Void) throws {
        window?.close()

        let model = try QuickAssistantImageEditorModel(sourceURL: source)
        model.onSaved = onSaved
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit " + source.lastPathComponent
        window.minSize = NSSize(width: 820, height: 580)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: QuickAssistantImageEditorView(
                model: model,
                onClose: { [weak self] in self?.window?.close() }
            )
        )
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.model = model
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
    }
}

private struct QuickAssistantImageEditorView: View {
    @ObservedObject var model: QuickAssistantImageEditorModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            editorCanvas
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Image Editor")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Everything runs on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            editorSection("BACKGROUND") {
                Button {
                    model.removeBackgroundAutomatically()
                } label: {
                    Label("Remove Automatically", systemImage: "person.and.background.dotted")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isProcessing)

                Picker(
                    "Background",
                    selection: Binding(
                        get: { model.backgroundStyle },
                        set: model.setBackgroundStyle
                    )
                ) {
                    ForEach(QuickAssistantImageEditorModel.BackgroundStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()

                if model.backgroundStyle == .color {
                    ColorPicker(
                        "Background color",
                        selection: Binding(
                            get: { model.backgroundColor },
                            set: model.setBackgroundColor
                        ),
                        supportsOpacity: false
                    )
                }

                if model.backgroundStyle == .photo {
                    Button(action: model.chooseBackgroundPhoto) {
                        Label(
                            model.backgroundPhotoName.map { "Change \($0)" } ?? "Choose Image…",
                            systemImage: "photo.on.rectangle"
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(model.isProcessing)
                }
            }

            editorSection("OBJECT ERASER") {
                Picker(
                    "Brush",
                    selection: $model.brushTool
                ) {
                    ForEach(QuickAssistantImageEditorModel.BrushTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.icon).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                    Slider(value: $model.brushSize, in: 8...180)
                    Image(systemName: "circle.fill")
                        .font(.system(size: 17))
                }
                Text("Brush over objects to erase them. Restore paints original pixels back.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            editorSection("HISTORY") {
                HStack {
                    Button(action: model.undo) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!model.canUndo || model.isProcessing)
                    Button(action: model.redo) {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!model.canRedo || model.isProcessing)
                }
                Button(action: model.resetMask) {
                    Label("Restore Original", systemImage: "arrow.counterclockwise")
                }
                .disabled(model.isProcessing)
            }

            Spacer()

            Text(model.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Close", action: onClose)
                Spacer()
                Button("Save…", action: model.save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.isProcessing)
            }
        }
        .padding(20)
        .frame(width: 248)
        .background(.ultraThinMaterial)
    }

    private func editorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var editorCanvas: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                checkerboard
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let preview = model.previewImage {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .allowsHitTesting(false)
                }
                if model.isProcessing {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.black.opacity(0.28))
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .padding(28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if value.translation == .zero {
                            model.beginStroke()
                        }
                        model.paint(
                            at: CGPoint(
                                x: value.location.x - 28,
                                y: value.location.y - 28
                            ),
                            canvasSize: CGSize(
                                width: max(1, proxy.size.width - 56),
                                height: max(1, proxy.size.height - 56)
                            )
                        )
                    }
                    .onEnded { _ in model.endStroke() }
            )
        }
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let tile: CGFloat = 14
            let columns = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(column) * tile,
                            y: CGFloat(row) * tile,
                            width: tile,
                            height: tile
                        )),
                        with: .color(.secondary.opacity(0.12))
                    )
                }
            }
        }
        .aspectRatio(model.aspectRatio, contentMode: .fit)
    }
}
