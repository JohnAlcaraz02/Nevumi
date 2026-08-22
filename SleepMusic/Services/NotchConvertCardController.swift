import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchConvertCardModel: ObservableObject {
    enum Phase {
        case choosing
        case working(String)
        case done
        case failed
    }

    @Published private(set) var files: [URL] = []
    @Published private(set) var formats: [AssistantConversionFormat] = []
    @Published private(set) var outputs: [URL] = []
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var errorMessage: String?

    var onFinished: (() -> Void)?

    func configure(files newFiles: [URL]) {
        files = newFiles
        outputs = []
        errorMessage = nil
        formats = Self.commonFormats(for: files)
        if formats.isEmpty {
            phase = .failed
            errorMessage = "No conversion is available for this file type."
        } else {
            phase = .choosing
        }
    }

    var title: String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }

    var subtitle: String {
        files.count == 1 ? "Drop to convert" : "Drop to convert all"
    }

    func convert(to format: AssistantConversionFormat) {
        guard case .choosing = phase, !files.isEmpty, formats.contains(format) else { return }

        let needsFolderChoice = files.contains {
            QuickAssistantFileConverter.needsDestinationFolder(source: $0, format: format)
        }
        let folder: URL?
        if needsFolderChoice {
            folder = Self.chooseFolder()
        } else {
            folder = files[0].deletingLastPathComponent()
        }
        guard let folder else { return }

        let sources = files
        Task { [weak self] in
            guard let self else { return }
            do {
                phase = .working("Reading…")
                var inputs: [QuickAssistantFileConverter.BatchInput] = []
                for source in sources {
                    let attachment = try await AssistantFileAnalyzer.analyze(source)
                    inputs.append(.init(source: source, extractedText: attachment.extractedText))
                }

                phase = .working("Converting to \(format.displayName)…")
                let produced = try await Task.detached(priority: .userInitiated) {
                    try QuickAssistantFileConverter.convertBatch(inputs, to: format, folder: folder)
                }.value

                outputs = produced
                phase = .done
                onFinished?()
            } catch is CancellationError {
                phase = .choosing
            } catch {
                errorMessage = error.localizedDescription
                phase = .failed
            }
        }
    }

    func revealOutputs() {
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    private static func commonFormats(for urls: [URL]) -> [AssistantConversionFormat] {
        guard let first = urls.first else { return [] }
        let initial = QuickAssistantFileConverter.availableFormats(for: first)
        return initial.filter { format in
            urls.dropFirst().allSatisfy {
                QuickAssistantFileConverter.availableFormats(for: $0).contains(format)
            }
        }
    }

    private static func chooseFolder() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Convert Here"
        panel.message = "Choose where the converted pages should be saved."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
final class NotchConvertCardController {
    static let shared = NotchConvertCardController()

    private static let cardWidth: CGFloat = 440
    private static let cardHeight: CGFloat = 118

    private let model = NotchConvertCardModel()
    private var panel: NotchConvertCardPanel?
    private var autoHideTask: Task<Void, Never>?

    private init() {
        model.onFinished = { [weak self] in self?.scheduleAutoHide() }
    }

    func present(files: [URL]) {
        autoHideTask?.cancel()
        autoHideTask = nil
        model.configure(files: files)

        let panel = panel ?? makePanel()
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NotchConvertCardPanel {
        let size = NSSize(width: Self.cardWidth, height: Self.cardHeight)
        let panel = NotchConvertCardPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: NotchConvertCardView(
                model: model,
                onClose: { [weak self] in self?.hide() }
            )
        )
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main else { return }
        let width = Self.cardWidth
        let height = Self.cardHeight
        let origin = NSPoint(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - screen.safeAreaInsets.top - height - 8
        )
        panel.setFrameOrigin(origin)
    }

    private func scheduleAutoHide(seconds: TimeInterval = 8) {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }
}

private final class NotchConvertCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct NotchConvertCardView: View {
    @ObservedObject var model: NotchConvertCardModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header

            switch model.phase {
            case .choosing:
                formatPicker
            case .working(let label):
                workingRow(label)
            case .done:
                doneRow
            case .failed:
                failedRow
            }
        }
        .padding(16)
        .frame(width: 440, height: 118)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.indigo)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(model.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var formatPicker: some View {
        VStack(spacing: 10) {
            Text("Choose a format")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(model.formats) { format in
                    Button {
                        model.convert(to: format)
                    } label: {
                        Text(format.displayName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                }
            }
        }
    }

    private func workingRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var doneRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Converted")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(destinationSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Show in Finder") {
                model.revealOutputs()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            Button("Done") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
    }

    private var failedRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(errorMessageText)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Button("OK") {
                onClose()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private var errorMessageText: String {
        if let errorMessage = model.errorMessage {
            return errorMessage
        }
        return "Conversion failed."
    }

    private var destinationSummary: String {
        guard let first = model.outputs.first else { return "" }
        if model.outputs.count == 1 {
            return first.deletingLastPathComponent().path
        }
        let folder = first.hasDirectoryPath
            ? first
            : first.deletingLastPathComponent()
        return "\(model.outputs.count) items in \(folder.path)"
    }

    private var icon: String {
        guard let file = model.files.first else { return "doc" }
        switch file.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp":
            return "photo"
        case "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "caf", "flac":
            return "waveform"
        default: return "doc.text"
        }
    }
}
