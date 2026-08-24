import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickAssistantView: View {
    @ObservedObject var viewModel: QuickAssistantViewModel
    let onClose: () -> Void

    @FocusState private var isInputFocused: Bool
    @State private var isFileTargeted = false

    private let suggestions = [
        "What song is playing?",
        "Summarize my clipboard",
        "Enter Sleep Mode",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            if let attachment = viewModel.attachment {
                attachmentBar(attachment)
            }
            content
            inputBar
        }
        .frame(width: 540, height: 390)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .onAppear { focusInput() }
        .onChange(of: viewModel.focusRequest) { _, _ in focusInput() }
        .overlay {
            if isFileTargeted { fileDropOverlay }
        }
        .onDrop(of: [.fileURL], isTargeted: $isFileTargeted, perform: handleFileDrop)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.indigo)
            Text("Quick Assistant")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer()
            Text("⌥ Space")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.07), in: Capsule())
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    private var content: some View {
        Group {
            if viewModel.isWorking
                || viewModel.isAnalyzingAttachment
                || viewModel.isConverting
                || viewModel.isRemovingBackground
                || viewModel.isEnhancingImage {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(activityLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if !viewModel.response.isEmpty {
                ScrollView {
                    Text(viewModel.response)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
            } else {
                VStack(spacing: 14) {
                    Text("What can I help you with?")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))

                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { viewModel.useSuggestion(suggestion) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }

                    Text("or drop a PDF, image, audio, or text file anywhere on this card")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func attachmentBar(_ attachment: QuickAssistantAttachment) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: attachmentIcon(for: attachment.url))
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.attachments.count == 1
                        ? attachment.name
                        : "\(attachment.name) and \(viewModel.attachments.count - 1) more")
                        .lineLimit(1)
                    Text(viewModel.attachments.count == 1
                        ? attachment.typeName
                        : "\(viewModel.attachments.count) files")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: viewModel.removeAttachment) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                attachmentAction("Summarize", icon: "text.alignleft")
                attachmentAction("Explain", icon: "lightbulb")
                attachmentAction("Extract", prompt: "Extract text", icon: "text.viewfinder")

                if viewModel.canEnhanceImage || viewModel.canRemoveBackground {
                    Menu {
                        if viewModel.canEnhanceImage {
                            Button {
                                viewModel.enhanceImageAttachment()
                            } label: {
                                Label("Enhance Photo", systemImage: "wand.and.sparkles")
                            }
                        }
                        if viewModel.canRemoveBackground {
                            Button {
                                viewModel.removeBackgroundFromAttachment()
                            } label: {
                                Label("Remove Background", systemImage: "person.and.background.dotted")
                            }
                        }
                    } label: {
                        Label("Image", systemImage: "photo")
                    }
                    .menuStyle(.button)
                    .controlSize(.mini)
                    .disabled(
                        viewModel.isWorking
                            || viewModel.isAnalyzingAttachment
                            || viewModel.isConverting
                            || viewModel.isRemovingBackground
                            || viewModel.isEnhancingImage
                    )
                }

                Menu {
                    ForEach(viewModel.availableConversionFormats) { format in
                        Button("Convert to \(format.displayName)") {
                            viewModel.convertAttachment(to: format)
                        }
                    }
                } label: {
                    Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                }
                .menuStyle(.button)
                .controlSize(.mini)
                .disabled(viewModel.availableConversionFormats.isEmpty || viewModel.isConverting)

                Menu {
                    Button("Suggest a filename") {
                        viewModel.useSuggestion("Suggest a filename")
                    }

                    Menu("After Conversion") {
                        ForEach(AssistantAutomaticOutputAction.allCases) { action in
                            Button {
                                viewModel.setAutomaticOutputAction(action)
                            } label: {
                                if viewModel.automaticOutputAction == action {
                                    Label(action.displayName, systemImage: "checkmark")
                                } else {
                                    Text(action.displayName)
                                }
                            }
                        }
                    }

                    if !viewModel.convertedFiles.isEmpty {
                        Divider()
                        Button("Show Converted File in Finder") {
                            viewModel.revealConvertedFiles()
                        }
                        Button("Copy Converted File") {
                            viewModel.copyConvertedFiles()
                        }
                        Button("Compress to ZIP…") {
                            viewModel.compressConvertedFiles()
                        }
                        Button("Rename Converted File…") {
                            viewModel.renameConvertedFile()
                        }
                        .disabled(viewModel.convertedFiles.count != 1)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .controlSize(.mini)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.16))
    }

    private func attachmentAction(_ title: String, prompt: String? = nil, icon: String) -> some View {
        Button {
            viewModel.useSuggestion(prompt ?? title)
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .disabled(viewModel.isWorking || viewModel.isAnalyzingAttachment || viewModel.isConverting)
    }

    private var fileDropOverlay: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.indigo.opacity(0.24))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 30))
                    Text("Drop to attach")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("One or more PDFs, images, audio, text, or source files")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.indigo, style: StrokeStyle(lineWidth: 2, dash: [7]))
            }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            viewModel.attachFiles(urls)
        }
        return true
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image, .audio, .plainText, .sourceCode]
        guard panel.runModal() == .OK else { return }
        viewModel.attachFiles(panel.urls)
    }

    private func attachmentIcon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp": return "photo"
        case "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "caf", "flac": return "waveform"
        default: return "doc.text"
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button(action: chooseFile) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Attach a file")
            Image(systemName: "command")
                .foregroundStyle(.secondary)
            TextField("Ask or tell SleepMusic what to do…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .onSubmit(viewModel.submit)
            Button(action: viewModel.submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Color.indigo, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(
                viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.isWorking
                    || viewModel.isConverting
                    || viewModel.isRemovingBackground
                    || viewModel.isEnhancingImage
                    || viewModel.isAnalyzingAttachment
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.black.opacity(0.2))
    }

    private func focusInput() {
        DispatchQueue.main.async { isInputFocused = true }
    }

    private var activityLabel: String {
        if viewModel.isAnalyzingAttachment { return "Reading the file…" }
        if viewModel.isEnhancingImage { return "Enhancing the photo on this Mac…" }
        if viewModel.isRemovingBackground { return "Removing the background on this Mac…" }
        if viewModel.isConverting { return "Converting the file…" }
        return "Thinking on this Mac…"
    }
}
