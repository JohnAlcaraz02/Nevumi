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
    @Published var selectedFormat: AssistantConversionFormat = .png
    @Published private(set) var fileIcon: NSImage?
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var errorMessage: String?

    var onFinished: (() -> Void)?

    func configure(files newFiles: [URL]) {
        files = newFiles
        outputs = []
        errorMessage = nil
        formats = Self.commonFormats(for: files)
        selectedFormat = formats.first ?? .png
        fileIcon = files.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
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
        switch phase {
        case .choosing: return files.count == 1 ? "Choose a format" : "Choose a format for all files"
        case .working: return "Your original files are kept"
        case .done: return "Ready to use"
        case .failed: return "Couldn't convert this file"
        }
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

    private static let cardWidth: CGFloat = 380
    private static let cardHeight: CGFloat = 144

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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct NotchConvertCardView: View {
    @ObservedObject var model: NotchConvertCardModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

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
        .padding(20)
        .frame(width: 380, height: 144)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let fileIcon = model.fileIcon {
                    Image(nsImage: fileIcon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(panelTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.title)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
        }
    }

    private var panelTitle: String {
        switch model.phase {
        case .choosing: return model.files.count == 1 ? "Convert File" : "Convert Files"
        case .working: return "Converting…"
        case .done: return "Conversion Complete"
        case .failed: return "Unable to Convert"
        }
    }

    private var formatPicker: some View {
        HStack(spacing: 12) {
            Picker("Format:", selection: $model.selectedFormat) {
                ForEach(model.formats) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 195)
            Spacer(minLength: 0)
            Button("Convert") {
                model.convert(to: model.selectedFormat)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.formats.isEmpty)
        }
        .controlSize(.regular)
    }

    private func workingRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: 12))
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
                    .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 11))
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

}
