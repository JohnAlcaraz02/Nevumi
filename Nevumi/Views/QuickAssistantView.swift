import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickAssistantView: View {
    @ObservedObject var viewModel: QuickAssistantViewModel
    let onClose: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @FocusState private var isInputFocused: Bool
    @FocusState private var isCalendarTitleFocused: Bool
    @State private var isFileTargeted = false
    @State private var isCalendarButtonHovered = false
    @State private var isConversationMenuHovered = false
    @State private var isCloseButtonHovered = false
    @State private var hoveredSuggestion: String?

    private let suggestions: [(title: String, icon: String, prompt: String)] = [
        ("Now Playing", "music.note", "What song is playing?"),
        ("Add Calendar Note", "calendar", "Add calendar note"),
        ("Enter Sleep Mode", "moon", "Enter Sleep Mode"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let attachment = viewModel.attachment,
               !viewModel.isShowingCalendarComposer {
                attachmentBar(attachment)
            }
            content
            if !viewModel.isShowingCalendarComposer {
                inputBar
            }
        }
        .frame(width: 540, height: panelHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .onAppear {
            onHeightChange(panelHeight)
            focusInput()
        }
        .onChange(of: viewModel.focusRequest) { _, _ in focusInput() }
        .onChange(of: viewModel.isShowingCalendarComposer) { _, isShowing in
            onHeightChange(isShowing ? 318 : 390)
            if isShowing {
                isInputFocused = false
                DispatchQueue.main.async { isCalendarTitleFocused = true }
            } else {
                focusInput()
            }
        }
        .overlay {
            if isFileTargeted { fileDropOverlay }
        }
        .onDrop(of: [.fileURL], isTargeted: $isFileTargeted, perform: handleFileDrop)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("NevumiMark")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 14)
                .foregroundStyle(Color(red: 0.72, green: 0.65, blue: 1))
            Text("Quick Assistant")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("⌥ Space")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
            Button {
                viewModel.showCalendarComposer()
            } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(
                        isCalendarButtonHovered ? Color.primary.opacity(0.07) : Color.clear,
                        in: Circle()
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add a calendar note")
            .accessibilityLabel("Add a calendar note")
            .onHover { isCalendarButtonHovered = $0 }
            Menu {
                Button {
                    viewModel.startNewConversation()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                .disabled(!viewModel.canStartNewConversation)

                Divider()

                Button {
                    viewModel.setConversationHistoryEnabled(
                        !viewModel.savesConversationHistory
                    )
                } label: {
                    if viewModel.savesConversationHistory {
                        Label("Keep History on This Mac", systemImage: "checkmark")
                    } else {
                        Text("Keep History on This Mac")
                    }
                }

                Divider()

                Button {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        LongScreenshotController.shared.start()
                    }
                } label: {
                    Label("Capture Long Screenshot…", systemImage: "rectangle.expand.vertical")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(
                        isConversationMenuHovered ? Color.primary.opacity(0.07) : Color.clear,
                        in: Circle()
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Conversation options")
            .accessibilityLabel("Conversation options")
            .onHover { isConversationMenuHovered = $0 }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(
                        isCloseButtonHovered ? Color.primary.opacity(0.07) : Color.clear,
                        in: Circle()
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close Quick Assistant")
            .accessibilityLabel("Close Quick Assistant")
            .onHover { isCloseButtonHovered = $0 }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
    }

    private var content: some View {
        Group {
            if viewModel.isShowingCalendarComposer {
                calendarComposer
            } else if !viewModel.messages.isEmpty || isAssistantBusy {
                conversation
            } else {
                VStack(spacing: 16) {
                    VStack(spacing: 5) {
                        Text("How can I help?")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Ask a question or choose an action.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(suggestions, id: \.title) { suggestion in
                            Button {
                                viewModel.useSuggestion(suggestion.prompt)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: suggestion.icon)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color(nsColor: .systemBlue))
                                        .frame(width: 20)
                                    Text(suggestion.title)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 33)
                                .contentShape(Rectangle())
                                .background(.primary.opacity(hoveredSuggestion == suggestion.title ? 0.06 : 0))
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredSuggestion = $0 ? suggestion.title : nil }
                            if suggestion.title != suggestions.last?.title {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(width: 290)

                    Text("Drop files here to work with them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        messageRow(message)
                            .id(message.id.uuidString)
                    }

                    if isAssistantBusy {
                        activityRow
                            .id("assistant-activity")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onAppear {
                scrollConversationToBottom(using: proxy, animated: false)
            }
            .onChange(of: viewModel.messages.last?.id) { _, _ in
                scrollConversationToBottom(using: proxy)
            }
            .onChange(of: isAssistantBusy) { _, _ in
                scrollConversationToBottom(using: proxy)
            }
        }
    }

    private func messageRow(_ message: QuickAssistantMessage) -> some View {
        let isUser = message.role == .user
        let isLatest = viewModel.messages.last?.id == message.id

        return HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 62) }

            if !isUser {
                Image("NevumiMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 10)
                    .foregroundStyle(Color(red: 0.72, green: 0.65, blue: 1))
                    .frame(width: 24, height: 24)
                    .background(Color(nsColor: .systemBlue).opacity(0.13), in: Circle())
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(isUser ? Color.white : Color.primary.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        isUser ? Color(nsColor: .systemBlue) : Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                if !message.context.isEmpty {
                    contextChips(message.context)
                }

                if !isUser {
                    messageActions(message, isLatest: isLatest)
                }
            }

            if !isUser { Spacer(minLength: 38) }
        }
        .frame(maxWidth: .infinity)
    }

    private func contextChips(_ context: [QuickAssistantContextChip]) -> some View {
        HStack(spacing: 5) {
            ForEach(context.prefix(3)) { item in
                Label(item.label, systemImage: item.systemImage)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.045), in: Capsule())
            }
        }
        .foregroundStyle(.secondary)
    }

    private func messageActions(
        _ message: QuickAssistantMessage,
        isLatest: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Button {
                viewModel.copyMessage(message)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy response")

            Button {
                viewModel.saveMessage(message)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save response")

            ShareLink(item: message.text) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Share response")

            if viewModel.canRetry(message) {
                Button {
                    viewModel.retryLastResponse()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Retry response")
            }

            if isLatest && message.allowsRetry {
                Divider().frame(height: 12)
                Button("Shorter") {
                    viewModel.useSuggestion("Make that shorter")
                }
                Button("More detail") {
                    viewModel.useSuggestion("Give me more detail")
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private var activityRow: some View {
        HStack(spacing: 8) {
            Image("NevumiMark")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 10)
                .foregroundStyle(Color(red: 0.72, green: 0.65, blue: 1))
                .frame(width: 24, height: 24)
                .background(Color(nsColor: .systemBlue).opacity(0.13), in: Circle())
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(activityLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.06), in: Capsule())
            Spacer()
        }
    }

    private var isAssistantBusy: Bool {
        viewModel.isWorking
            || viewModel.isAnalyzingAttachment
            || viewModel.isConverting
            || viewModel.isRemovingBackground
            || viewModel.isChangingBackgroundColor
            || viewModel.isGeneratingBackground
            || viewModel.isEnhancingImage
    }

    private func scrollConversationToBottom(
        using proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        let target = isAssistantBusy
            ? "assistant-activity"
            : viewModel.messages.last?.id.uuidString
        guard let target else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    private var calendarComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color(nsColor: .systemBlue).opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("New calendar note")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Saves to your default calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 9) {
                TextField("What’s happening?", text: $viewModel.calendarEntryTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($isCalendarTitleFocused)
                    .onSubmit(viewModel.saveCalendarEntry)

                TextField("Add a note (optional)", text: $viewModel.calendarEntryNotes)
                    .textFieldStyle(.roundedBorder)

                Divider().overlay(.primary.opacity(0.06))

                HStack(spacing: 10) {
                    Label("When", systemImage: "clock")
                        .frame(width: 62, alignment: .leading)
                        .foregroundStyle(.secondary)
                    DatePicker(
                        "",
                        selection: $viewModel.calendarEntryStartDate,
                        displayedComponents: viewModel.calendarEntryIsAllDay
                            ? [.date]
                            : [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    Spacer(minLength: 4)
                    Toggle("All day", isOn: $viewModel.calendarEntryIsAllDay)
                        .toggleStyle(.checkbox)
                }

                if !viewModel.calendarEntryIsAllDay {
                    HStack(spacing: 10) {
                        Label("Length", systemImage: "timer")
                            .frame(width: 62, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Picker(
                            "",
                            selection: $viewModel.calendarEntryDurationMinutes
                        ) {
                            Text("15m").tag(15)
                            Text("30m").tag(30)
                            Text("1h").tag(60)
                            Text("2h").tag(120)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(10)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
                    .allowsHitTesting(false)
            }

            if !viewModel.calendarComposerError.isEmpty {
                Label(viewModel.calendarComposerError, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Label("Write-only access", systemImage: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button("Cancel", action: viewModel.closeCalendarComposer)
                    .disabled(viewModel.isSavingCalendarEntry)
                Button(action: viewModel.saveCalendarEntry) {
                    HStack(spacing: 6) {
                        if viewModel.isSavingCalendarEntry {
                            ProgressView().controlSize(.small)
                        }
                        Text(viewModel.isSavingCalendarEntry ? "Adding…" : "Add to Calendar")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSavingCalendarEntry)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var panelHeight: CGFloat {
        viewModel.isShowingCalendarComposer ? 318 : 390
    }

    private func attachmentBar(_ attachment: QuickAssistantAttachment) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: attachmentIcon(for: attachment.url))
                    .foregroundStyle(Color(nsColor: .systemBlue))
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
                        if viewModel.canEditImage {
                            Button {
                                viewModel.editImageAttachment()
                            } label: {
                                Label("Open Image Editor…", systemImage: "slider.horizontal.3")
                            }
                            Divider()
                        }
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
                            || viewModel.isChangingBackgroundColor
                            || viewModel.isGeneratingBackground
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
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.025))
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
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 30))
                    Text("Drop to attach")
                        .font(.system(size: 16, weight: .semibold))
                    Text("One or more PDFs, images, audio, text, or source files")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .systemBlue).opacity(0.7), lineWidth: 2)
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

    private var canSubmit: Bool {
        !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAssistantBusy
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button(action: chooseFile) {
                Image(systemName: "paperclip")
                    .font(.system(size: 15))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Attach a file")
            .accessibilityLabel("Attach a file")

            TextField("Message Nevumi…", text: $viewModel.query)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .onSubmit { if canSubmit { viewModel.submit() } }

            Button(action: viewModel.submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                    .background(canSubmit ? Color(nsColor: .systemBlue) : Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help("Send message")
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .padding(14)
    }

    private func focusInput() {
        guard !viewModel.isShowingCalendarComposer else { return }
        DispatchQueue.main.async {
            isCalendarTitleFocused = false
            isInputFocused = true
        }
    }

    private var activityLabel: String {
        if viewModel.isAnalyzingAttachment { return "Reading the file…" }
        if viewModel.isEnhancingImage { return "Enhancing the photo on this Mac…" }
        if viewModel.isGeneratingBackground { return "Generating and applying the new background…" }
        if viewModel.isChangingBackgroundColor { return "Changing the background color on this Mac…" }
        if viewModel.isRemovingBackground { return "Removing the background on this Mac…" }
        if viewModel.isConverting { return "Converting the file…" }
        return "Thinking on this Mac…"
    }
}
