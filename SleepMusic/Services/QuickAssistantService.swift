import AppKit
import Foundation
import FoundationModels
import PDFKit
import UniformTypeIdentifiers
import Vision

struct QuickAssistantAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let typeName: String
    let extractedText: String

    var name: String { url.lastPathComponent }
    var hasReadableText: Bool { !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum QuickAssistantMessageRole: String, Codable {
    case user
    case assistant
}

struct QuickAssistantContextChip: Identifiable, Codable, Equatable {
    let id: UUID
    let label: String
    let systemImage: String

    init(id: UUID = UUID(), label: String, systemImage: String) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
    }
}

struct QuickAssistantMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: QuickAssistantMessageRole
    var text: String
    let createdAt: Date
    var context: [QuickAssistantContextChip]
    var allowsRetry: Bool

    init(
        id: UUID = UUID(),
        role: QuickAssistantMessageRole,
        text: String,
        createdAt: Date = Date(),
        context: [QuickAssistantContextChip] = [],
        allowsRetry: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.context = context
        self.allowsRetry = allowsRetry
    }
}

enum AssistantAutomaticOutputAction: String, CaseIterable, Identifiable {
    case none
    case reveal
    case copy
    case compress

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Do Nothing"
        case .reveal: return "Reveal in Finder"
        case .copy: return "Copy to Clipboard"
        case .compress: return "Compress to ZIP"
        }
    }
}

@MainActor
final class QuickAssistantViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var response = ""
    @Published private(set) var messages: [QuickAssistantMessage] = []
    @Published private(set) var savesConversationHistory = false
    @Published private(set) var isWorking = false
    @Published private(set) var focusRequest = 0
    @Published private(set) var attachments: [QuickAssistantAttachment] = []
    @Published private(set) var isAnalyzingAttachment = false
    @Published private(set) var isConverting = false
    @Published private(set) var isRemovingBackground = false
    @Published private(set) var isChangingBackgroundColor = false
    @Published private(set) var isEnhancingImage = false
    @Published private(set) var isShowingCalendarComposer = false
    @Published private(set) var isSavingCalendarEntry = false
    @Published private(set) var calendarComposerError = ""
    @Published var calendarEntryTitle = ""
    @Published var calendarEntryNotes = ""
    @Published var calendarEntryStartDate = Date()
    @Published var calendarEntryDurationMinutes = 60
    @Published var calendarEntryIsAllDay = false
    @Published private(set) var convertedFiles: [URL] = []
    @Published private(set) var automaticOutputAction: AssistantAutomaticOutputAction = .none

    private let spotify: SpotifyObserver
    private let lyrics: LyricsViewModel
    private let calendarService = QuickAssistantCalendarService()
    private var requestTask: Task<Void, Never>?
    private static let historyEnabledKey = "assistantSavesConversationHistory"
    private static let savedMessagesKey = "assistantConversationMessages"
    private static let maximumSavedMessages = 100
    private static let maximumSavedMessageCharacters = 20_000
    private static let maximumTranscriptCharacters = 6_000
    private static let modelInstructions = """
    You are the concise personal assistant inside a small Mac notch panel.
    Answer in plain text using at most four short sentences unless the user
    explicitly asks for detail. Never claim that you performed an action.
    Music and Sleep Mode actions are handled separately by the app.
    """

    init(spotify: SpotifyObserver, lyrics: LyricsViewModel) {
        self.spotify = spotify
        self.lyrics = lyrics
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "assistantAutomaticOutputAction"),
           let action = AssistantAutomaticOutputAction(rawValue: stored) {
            automaticOutputAction = action
        }
        savesConversationHistory = defaults.bool(forKey: Self.historyEnabledKey)
        if savesConversationHistory,
           let data = defaults.data(forKey: Self.savedMessagesKey),
           let saved = try? JSONDecoder().decode([QuickAssistantMessage].self, from: data) {
            messages = Array(saved.suffix(Self.maximumSavedMessages))
            response = messages.last(where: { $0.role == .assistant })?.text ?? ""
        }
    }

    var attachment: QuickAssistantAttachment? { attachments.first }

    deinit {
        requestTask?.cancel()
    }

    func prepareForPresentation() {
        focusRequest += 1
    }

    func startNewConversation() {
        requestTask?.cancel()
        requestTask = nil
        isWorking = false
        isAnalyzingAttachment = false
        isConverting = false
        isRemovingBackground = false
        isChangingBackgroundColor = false
        isEnhancingImage = false
        isShowingCalendarComposer = false
        isSavingCalendarEntry = false
        calendarComposerError = ""
        attachments = []
        convertedFiles = []
        query = ""
        response = ""
        messages = []
        persistMessages()
        focusRequest += 1
    }

    func setConversationHistoryEnabled(_ isEnabled: Bool) {
        savesConversationHistory = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.historyEnabledKey)
        if isEnabled {
            persistMessages()
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedMessagesKey)
        }
    }

    func copyMessage(_ message: QuickAssistantMessage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
    }

    func saveMessage(_ message: QuickAssistantMessage) {
        let panel = NSSavePanel()
        panel.title = "Save Assistant Response"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "SleepMusic Response.txt"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try Data(message.text.utf8).write(to: destination, options: .atomic)
        } catch {
            presentResponse("I couldn’t save that response. \(error.localizedDescription)")
        }
    }

    func canRetry(_ message: QuickAssistantMessage) -> Bool {
        !isBusy && messages.last?.id == message.id && message.allowsRetry
    }

    var canStartNewConversation: Bool {
        !isBusy && (!messages.isEmpty || !attachments.isEmpty)
    }

    func retryLastResponse() {
        guard let assistantIndex = messages.indices.last,
              messages[assistantIndex].role == .assistant,
              messages[assistantIndex].allowsRetry,
              !isBusy,
              let userIndex = messages[..<assistantIndex].lastIndex(where: { $0.role == .user })
        else { return }

        let request = messages[userIndex].text
        let history = Array(messages[..<userIndex])
        requestModelResponse(
            for: request,
            history: history,
            replacing: messages[assistantIndex].id
        )
    }

    private var isBusy: Bool {
        isWorking
            || isAnalyzingAttachment
            || isConverting
            || isRemovingBackground
            || isChangingBackgroundColor
            || isEnhancingImage
            || isSavingCalendarEntry
    }

    func useSuggestion(_ suggestion: String) {
        query = suggestion
        submit()
    }

    func showCalendarComposer(prefillCommand: String? = nil) {
        let now = Date().addingTimeInterval(30 * 60)
        let interval: TimeInterval = 15 * 60
        calendarEntryStartDate = Date(
            timeIntervalSince1970: ceil(now.timeIntervalSince1970 / interval) * interval
        )
        calendarEntryTitle = ""
        calendarEntryNotes = ""
        calendarEntryDurationMinutes = 60
        calendarEntryIsAllDay = false
        calendarComposerError = ""

        if let prefillCommand {
            let prefill = calendarPrefill(from: prefillCommand)
            calendarEntryTitle = prefill.title
            if let detectedDate = prefill.date {
                calendarEntryStartDate = detectedDate
            }
        }

        response = ""
        isShowingCalendarComposer = true
    }

    func closeCalendarComposer() {
        guard !isSavingCalendarEntry else { return }
        isShowingCalendarComposer = false
        calendarComposerError = ""
        focusRequest += 1
    }

    func saveCalendarEntry() {
        let title = calendarEntryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            calendarComposerError = "Add a title for the calendar note."
            return
        }
        guard !isSavingCalendarEntry else { return }

        calendarComposerError = ""
        isSavingCalendarEntry = true
        let entry = QuickAssistantCalendarEntry(
            title: title,
            notes: calendarEntryNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: calendarEntryStartDate,
            durationMinutes: calendarEntryDurationMinutes,
            isAllDay: calendarEntryIsAllDay
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let calendarName = try await calendarService.add(entry)
                let dateDescription = entry.isAllDay
                    ? entry.startDate.formatted(date: .abbreviated, time: .omitted)
                    : entry.startDate.formatted(date: .abbreviated, time: .shortened)
                presentResponse("Added “\(entry.title)” to \(calendarName) for \(dateDescription).")
                isShowingCalendarComposer = false
                focusRequest += 1
            } catch {
                calendarComposerError = error.localizedDescription
            }
            isSavingCalendarEntry = false
        }
    }

    func attachFile(_ url: URL) {
        attachFiles([url])
    }

    func attachFiles(_ urls: [URL]) {
        let uniqueURLs = Array(NSOrderedSet(array: urls).compactMap { $0 as? URL })
        guard !uniqueURLs.isEmpty else { return }

        requestTask?.cancel()
        isWorking = false
        isConverting = false
        isRemovingBackground = false
        isChangingBackgroundColor = false
        isEnhancingImage = false
        isAnalyzingAttachment = true
        attachments = []
        convertedFiles = []
        response = uniqueURLs.count == 1
            ? "Reading \(uniqueURLs[0].lastPathComponent)…"
            : "Reading \(uniqueURLs.count) files…"

        requestTask = Task { [weak self] in
            guard let self else { return }
            var analyzedFiles: [QuickAssistantAttachment] = []
            var failures: [String] = []

            for url in uniqueURLs {
                do {
                    analyzedFiles.append(try await AssistantFileAnalyzer.analyze(url))
                } catch is CancellationError {
                    return
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                guard !Task.isCancelled else { return }
            }

            attachments = analyzedFiles
            if analyzedFiles.isEmpty {
                presentResponse("I couldn’t attach those files. \(failures.first ?? "No supported files were found.")")
            } else if analyzedFiles.count == 1 {
                let analyzed = analyzedFiles[0]
                if QuickAssistantFileConverter.detectedContentType(for: analyzed.url)?.conforms(to: .audio) == true {
                    presentResponse(
                        "\(analyzed.name) is ready. Choose WAV, AIFF, or CAF from Convert.",
                        context: [.init(label: analyzed.name, systemImage: "paperclip")]
                    )
                } else {
                    presentResponse(
                        analyzed.hasReadableText
                            ? "\(analyzed.name) is ready. Ask a question or choose an action below."
                            : "I attached \(analyzed.name), but couldn’t find readable text in it.",
                        context: [.init(label: analyzed.name, systemImage: "paperclip")]
                    )
                }
            } else {
                let skipped = failures.isEmpty ? "" : " \(failures.count) unsupported file(s) were skipped."
                presentResponse(
                    "\(analyzedFiles.count) files are ready for analysis or batch conversion.\(skipped)",
                    context: analyzedFiles.prefix(3).map {
                        .init(label: $0.name, systemImage: "paperclip")
                    }
                )
            }
            isAnalyzingAttachment = false
            focusRequest += 1
        }
    }

    func removeAttachment() {
        requestTask?.cancel()
        isAnalyzingAttachment = false
        isConverting = false
        isRemovingBackground = false
        isChangingBackgroundColor = false
        isEnhancingImage = false
        attachments = []
        convertedFiles = []
        response = ""
        focusRequest += 1
    }

    func submit() {
        let request = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty,
              !isWorking,
              !isConverting,
              !isRemovingBackground,
              !isChangingBackgroundColor,
              !isEnhancingImage,
              !isSavingCalendarEntry,
              !isAnalyzingAttachment else { return }

        query = ""
        requestTask?.cancel()
        let history = messages
        appendMessage(role: .user, text: request)

        if handleConversionCommand(request) { return }

        if let localResponse = performLocalCommand(request) {
            if !isBusy {
                presentResponse(localResponse)
            }
            return
        }

        guard SystemLanguageModel.default.isAvailable else {
            presentResponse("Apple Intelligence is unavailable on this Mac. You can still say “play or pause,” “next song,” “previous song,” “what song is playing,” or “enter sleep mode.”")
            return
        }

        requestModelResponse(for: request, history: history)
    }

    var availableConversionFormats: [AssistantConversionFormat] {
        guard let first = attachments.first else { return [] }
        let firstFormats = QuickAssistantFileConverter.availableFormats(for: first.url)
        return firstFormats.filter { format in
            attachments.dropFirst().allSatisfy {
                QuickAssistantFileConverter.availableFormats(for: $0.url).contains(format)
            }
        }
    }

    func convertAttachment(to format: AssistantConversionFormat) {
        guard let attachment = attachments.first else {
            presentResponse("Attach a file before converting it.")
            return
        }
        guard availableConversionFormats.contains(format) else {
            presentResponse("\(format.displayName) isn’t available for this file type.")
            return
        }
        let destination: URL?
        if attachments.count > 1 {
            destination = chooseBatchConversionFolder()
        } else {
            destination = chooseConversionDestination(for: attachment, format: format)
        }
        guard let destination else { return }

        isConverting = true
        convertedFiles = []
        response = attachments.count == 1
            ? "Converting \(attachment.name) to \(format.displayName)…"
            : "Converting \(attachments.count) files to \(format.displayName)…"
        let filesToConvert = attachments
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { isConverting = false }
            do {
                let outputs = try await Task.detached(priority: .userInitiated) {
                    if filesToConvert.count > 1 {
                        return try QuickAssistantFileConverter.convertBatch(
                            filesToConvert.map {
                                .init(source: $0.url, extractedText: $0.extractedText)
                            },
                            to: format,
                            folder: destination
                        )
                    }
                    return try QuickAssistantFileConverter.convert(
                        source: attachment.url,
                        extractedText: attachment.extractedText,
                        to: format,
                        destination: destination
                    )
                }.value
                guard !Task.isCancelled else { return }
                convertedFiles = outputs
                if filesToConvert.count > 1 {
                    response = "Converted \(filesToConvert.count) files into \(outputs.count) output item(s)."
                } else {
                    response = outputs.count == 1
                        ? "Converted successfully to \(outputs[0].lastPathComponent)."
                        : "Converted \(outputs.count) PDF pages to \(format.displayName)."
                }
                do {
                    try await runAutomaticOutputAction()
                } catch {
                    response += " Automatic output action failed: \(error.localizedDescription)"
                }
                presentResponse(response)
            } catch is CancellationError {
                return
            } catch {
                presentResponse("Conversion failed. \(error.localizedDescription)")
            }
            focusRequest += 1
        }
    }

    var canRemoveBackground: Bool {
        guard let first = attachments.first else { return false }
        return QuickAssistantBackgroundRemover.canProcess(
            QuickAssistantFileConverter.detectedContentType(for: first.url)
        )
    }

    var canEnhanceImage: Bool {
        guard let first = attachments.first else { return false }
        return QuickAssistantImageEnhancer.canProcess(
            QuickAssistantFileConverter.detectedContentType(for: first.url)
        )
    }

    var canEditImage: Bool { canEnhanceImage }

    func editImageAttachment(initialBackgroundPrompt: String? = nil) {
        guard let attachment = attachments.first else {
            presentResponse("Drop an image here first, then I can open the editor.")
            return
        }
        guard canEditImage else {
            presentResponse("The image editor works with image files only.")
            return
        }

        do {
            try QuickAssistantImageEditorController.shared.present(
                source: attachment.url,
                initialBackgroundPrompt: initialBackgroundPrompt
            ) { [weak self] output in
                guard let self else { return }
                convertedFiles = [output]
                presentResponse("Saved the edited image as \(output.lastPathComponent).")
                focusRequest += 1
            }
            presentResponse("Opened \(attachment.name) in the offline image editor.")
        } catch {
            presentResponse("Couldn’t open the image editor. \(error.localizedDescription)")
        }
    }

    func enhanceImageAttachment() {
        guard let attachment = attachments.first else {
            presentResponse("Drop an image here first, then I can enhance it.")
            return
        }
        guard canEnhanceImage else {
            presentResponse("Photo enhancement works with image files only.")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Enhanced Photo"
        panel.prompt = "Enhance"
        panel.allowedContentTypes = [.jpeg, .png, .tiff]
        panel.canCreateDirectories = true
        panel.directoryURL = attachment.url.deletingLastPathComponent()
        panel.nameFieldStringValue = QuickAssistantImageEnhancer.enhancedFilename(
            for: attachment.url
        )
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isEnhancingImage = true
        convertedFiles = []
        response = "Enhancing \(attachment.name) on this Mac…"
        let source = attachment.url
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { isEnhancingImage = false }
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try QuickAssistantImageEnhancer.enhance(
                        source: source,
                        destination: destination
                    )
                }.value
                guard !Task.isCancelled else { return }
                convertedFiles = [output]
                response = "Enhanced the photo and saved \(output.lastPathComponent)."
                do {
                    try await runAutomaticOutputAction()
                } catch {
                    response += " Automatic output action failed: \(error.localizedDescription)"
                }
                presentResponse(response)
            } catch is CancellationError {
                return
            } catch {
                presentResponse("Couldn’t enhance the photo. \(error.localizedDescription)")
            }
            focusRequest += 1
        }
    }

    func removeBackgroundFromAttachment() {
        guard let attachment = attachments.first else {
            presentResponse("Drop an image here first, then I can remove its background.")
            return
        }
        guard canRemoveBackground else {
            presentResponse("Removing backgrounds works with image files only.")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Image Without Background"
        panel.prompt = "Remove Background"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = attachment.url.deletingLastPathComponent()
        panel.nameFieldStringValue = attachment.url
            .deletingPathExtension()
            .lastPathComponent + "-no-bg.png"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isRemovingBackground = true
        convertedFiles = []
        response = "Cutting the subject out of \(attachment.name)…"
        let source = attachment.url
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { isRemovingBackground = false }
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try await QuickAssistantBackgroundRemover.removeBackground(
                        from: source,
                        destination: destination
                    )
                }.value
                guard !Task.isCancelled else { return }
                convertedFiles = [output]
                response = "Removed the background and saved \(output.lastPathComponent)."
                do {
                    try await runAutomaticOutputAction()
                } catch {
                    response += " Automatic output action failed: \(error.localizedDescription)"
                }
                presentResponse(response)
            } catch is CancellationError {
                return
            } catch {
                presentResponse("Couldn’t remove the background. \(error.localizedDescription)")
            }
            focusRequest += 1
        }
    }

    func changeBackgroundColor(
        to color: QuickAssistantBackgroundRemover.ReplacementColor
    ) {
        guard let attachment = attachments.first else {
            presentResponse("Drop an image here first, then tell me which background color to use.")
            return
        }
        guard canRemoveBackground else {
            presentResponse("Changing the background color works with image files only.")
            return
        }

        let proposed = attachment.url.deletingLastPathComponent().appendingPathComponent(
            QuickAssistantBackgroundRemover.replacementFilename(
                for: attachment.url,
                color: color
            )
        )
        let destination = QuickAssistantOutputActions.uniqueURL(for: proposed)
        isChangingBackgroundColor = true
        convertedFiles = []
        response = "Changing the background of \(attachment.name) to \(color.displayName)…"
        let source = attachment.url
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { isChangingBackgroundColor = false }
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try await QuickAssistantBackgroundRemover.replaceBackground(
                        from: source,
                        destination: destination,
                        color: color
                    )
                }.value
                guard !Task.isCancelled else { return }
                convertedFiles = [output]
                response = "Changed the background to \(color.displayName) and saved \(output.lastPathComponent)."
                do {
                    try await runAutomaticOutputAction()
                } catch {
                    response += " Automatic output action failed: \(error.localizedDescription)"
                }
                presentResponse(response)
            } catch is CancellationError {
                return
            } catch {
                presentResponse("Couldn’t change the background color. \(error.localizedDescription)")
            }
            focusRequest += 1
        }
    }

    func revealConvertedFiles() {
        guard !convertedFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(convertedFiles)
    }

    func setAutomaticOutputAction(_ action: AssistantAutomaticOutputAction) {
        automaticOutputAction = action
        UserDefaults.standard.set(action.rawValue, forKey: "assistantAutomaticOutputAction")
        presentResponse(action == .none
            ? "Automatic output actions are off."
            : "After conversion, SleepMusic will \(action.displayName.lowercased()).")
    }

    func copyConvertedFiles() {
        guard copyOutputsToClipboard() else {
            presentResponse("There are no converted files to copy.")
            return
        }
        presentResponse(convertedFiles.count == 1
            ? "Copied the converted file to the clipboard."
            : "Copied \(convertedFiles.count) converted files to the clipboard.")
    }

    func compressConvertedFiles() {
        guard !convertedFiles.isEmpty else {
            presentResponse("There are no converted files to compress.")
            return
        }
        guard let destination = chooseArchiveDestination(for: convertedFiles) else { return }
        compressConvertedFiles(to: destination)
    }

    func renameConvertedFile() {
        guard convertedFiles.count == 1, let source = convertedFiles.first else {
            presentResponse("Rename is available when there is exactly one converted file.")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Rename Converted File"
        panel.prompt = "Rename"
        panel.canCreateDirectories = true
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination != source else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            presentResponse(QuickAssistantOutputActions.OutputActionError.destinationExists.localizedDescription)
            return
        }

        do {
            try FileManager.default.moveItem(at: source, to: destination)
            convertedFiles = [destination]
            presentResponse("Renamed the converted file to \(destination.lastPathComponent).")
        } catch {
            presentResponse("Rename failed. \(error.localizedDescription)")
        }
    }

    private func performLocalCommand(_ request: String) -> String? {
        let command = request.lowercased().trimmingCharacters(in: .punctuationCharacters)

        if command.contains("calendar"),
           ["add", "create", "save", "put", "schedule", "note", "event"]
               .contains(where: { command.contains($0) }) {
            showCalendarComposer(prefillCommand: request)
            return ""
        }

        if command.contains("extract text") || command == "show text" {
            guard !attachments.isEmpty else { return "Drop a PDF, image, or text file here first." }
            let readable = attachments.filter(\.hasReadableText)
            guard !readable.isEmpty else { return "I couldn’t find readable text in the attached files." }
            return readable.map { "--- \($0.name) ---\n\($0.extractedText)" }.joined(separator: "\n\n")
        }

        let backgroundDescription = requestedBackgroundDescription(in: request)
        let backgroundColorIntent = command.contains("background")
            && (command.contains("background color")
                || command.contains("color of the background")
                || backgroundDescription.map(isPlainColorDescription) == true)
            && ["change", "make", "set", "replace", "turn", "use"]
                .contains(where: { command.contains($0) })
        if backgroundColorIntent {
            guard let color = QuickAssistantBackgroundRemover.replacementColor(in: command) else {
                return "Which color should I use? Try red, blue, white, black, or a hex color such as #4A90E2."
            }
            changeBackgroundColor(to: color)
            return response
        }

        if let backgroundDescription {
            editImageAttachment(initialBackgroundPrompt: backgroundDescription)
            return response
        }

        if command.contains("background"),
           ["remove", "erase", "delete", "cut out", "cutout", "get rid", "strip", "transparent", "isolate"]
               .contains(where: { command.contains($0) }) {
            removeBackgroundFromAttachment()
            return response
        }

        if command.contains("enhance")
            || command.contains("improve photo")
            || command.contains("improve image")
            || command.contains("improve picture") {
            enhanceImageAttachment()
            return response
        }

        if command.contains("edit image")
            || command.contains("edit photo")
            || command.contains("image editor")
            || command.contains("photo editor")
            || command.contains("erase object")
            || command.contains("remove object")
            || command.contains("delete object")
            || command.contains("erase thing")
            || command.contains("remove thing")
            || command.contains("delete thing")
            || command.contains("erase something")
            || command.contains("remove something")
            || command.contains("delete something")
            || command.contains("replace background")
            || command.contains("change background")
            || command.contains("edit background")
            || command.contains("edit bg") {
            editImageAttachment()
            return response
        }

        if command.contains("copy converted") || command == "copy outputs" {
            copyConvertedFiles()
            return response
        }
        if command.contains("compress converted") || command.contains("zip converted") || command == "compress outputs" {
            compressConvertedFiles()
            return response
        }
        if command.contains("rename converted") || command == "rename output" {
            renameConvertedFile()
            return response
        }
        if command.contains("after conversion") {
            if command.contains("compress") || command.contains("zip") {
                setAutomaticOutputAction(.compress)
            } else if command.contains("copy") || command.contains("clipboard") {
                setAutomaticOutputAction(.copy)
            } else if command.contains("reveal") || command.contains("finder") {
                setAutomaticOutputAction(.reveal)
            } else if command.contains("nothing") || command.contains("off") || command.contains("disable") {
                setAutomaticOutputAction(.none)
            } else {
                return "Choose an after-conversion action: reveal, copy, compress, or off."
            }
            return response
        }

        if ["play", "pause", "play or pause", "toggle music", "toggle playback"].contains(command) {
            spotify.togglePlayPause()
            return "Spotify playback toggled."
        }
        if ["next", "next song", "skip", "skip song", "skip track"].contains(command) {
            spotify.skipToNext()
            return "Skipping to the next Spotify track."
        }
        if ["previous", "previous song", "previous track", "go back"].contains(command) {
            spotify.skipToPrevious()
            return "Going back to the previous Spotify track."
        }
        if command.contains("sleep mode") {
            guard spotify.nowPlaying != nil else {
                return "Play something in Spotify before entering Sleep Mode."
            }
            SleepOverlayController.shared.show(spotify: spotify, lyrics: lyrics)
            return "Sleep Mode started. Click or press a key to leave it."
        }
        if command.contains("what song") || command.contains("what is playing") || command == "now playing" {
            guard let track = spotify.nowPlaying else { return "Spotify isn’t playing anything right now." }
            return "“\(track.title)” by \(track.artist) is currently \(track.isPlaying ? "playing" : "paused")."
        }
        if command == "help" || command == "what can you do" {
            return "Ask a question, add calendar notes, or drop files to analyze and convert. For images I can enhance photos, erase objects, remove backgrounds, use another photo, or generate a described background with Image Playground. I can also summarize clipboard text, control Spotify, check the current song, and enter Sleep Mode."
        }
        return nil
    }

    private func requestedBackgroundDescription(in request: String) -> String? {
        let patterns = [
            #"(?i)\bremove\s+(?:the\s+)?background\s+(?:and\s+)?replace\s+(?:it\s+)?with\s+(.+)$"#,
            #"(?i)\b(?:replace|change|swap|set|make|turn|use)\s+(?:the\s+)?background\s+(?:with|to|into|as)\s+(.+)$"#,
            #"(?i)\b(?:replace|change|swap|set|make|turn|use)\s+(?:the\s+)?background\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: request,
                    range: NSRange(request.startIndex..., in: request)
                  ),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: request)
            else { continue }
            let description = request[range].trimmingCharacters(
                in: .whitespacesAndNewlines.union(.punctuationCharacters)
            )
            let normalized = description.lowercased()
            if !description.isEmpty,
               !["transparent", "clear", "no background"].contains(normalized) {
                return String(description)
            }
        }
        return nil
    }

    private func isPlainColorDescription(_ description: String) -> Bool {
        description.range(
            of: #"(?i)^\s*(?:a\s+|an\s+)?(?:#[0-9a-f]{3}(?:[0-9a-f]{3})?|light\s+blue|dark\s+blue|navy(?:\s+blue)?|light\s+green|dark\s+green|light\s+gr[ae]y|dark\s+gr[ae]y|red|orange|yellow|green|mint|teal|cyan|aqua|blue|indigo|purple|violet|pink|magenta|brown|beige|cream|gr[ae]y|black|white)(?:\s+colou?r)?\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private func calendarPrefill(from command: String) -> (title: String, date: Date?) {
        var title = command
        var detectedDate: Date?
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) {
            let fullRange = NSRange(title.startIndex..., in: title)
            if let result = detector.firstMatch(
                in: title,
                options: [],
                range: fullRange
            ), let date = result.date {
                detectedDate = date
                title = (title as NSString).replacingCharacters(in: result.range, with: "")
            }
        }

        let cleanupPatterns = [
            #"(?i)^\s*calendar\s+(note|event)\s*[:\-]?\s*"#,
            #"(?i)^\s*(add|create|save|put|schedule)\s+"#,
            #"(?i)\s+(to|in|on)\s+(my\s+)?calendar\s*$"#,
            #"(?i)^\s*(a|an)\s+"#,
        ]
        for pattern in cleanupPatterns {
            title = title.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        title = title.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if [
            "calendar note",
            "calendar event",
            "to calendar",
            "to my calendar",
            "note",
            "event",
        ].contains(title.lowercased()) {
            title = ""
        }

        if let date = detectedDate, date < Date().addingTimeInterval(-60),
           let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date) {
            detectedDate = tomorrow
        }
        return (title, detectedDate)
    }

    private func handleConversionCommand(_ request: String) -> Bool {
        let command = request.lowercased()
        guard command.contains("convert") else { return false }
        guard !attachments.isEmpty else {
            presentResponse("Drop or attach a file before asking me to convert it.")
            return true
        }

        let requestedFormat: AssistantConversionFormat?
        if command.contains("png") {
            requestedFormat = .png
        } else if command.contains("jpeg") || command.contains("jpg") {
            requestedFormat = .jpeg
        } else if command.contains("tiff") || command.contains("tif") {
            requestedFormat = .tiff
        } else if command.contains("pdf") {
            requestedFormat = .pdf
        } else if command.contains("text") || command.contains("txt") {
            requestedFormat = .plainText
        } else if command.contains("wav") {
            requestedFormat = .wav
        } else if command.contains("aiff") || command.contains("aif") {
            requestedFormat = .aiff
        } else if command.contains("caf") {
            requestedFormat = .caf
        } else {
            presentResponse("Choose an output format from the Convert menu.")
            return true
        }

        guard let requestedFormat, availableConversionFormats.contains(requestedFormat) else {
            presentResponse("That output format isn’t available for the attached file.")
            return true
        }
        convertAttachment(to: requestedFormat)
        return true
    }

    private func chooseConversionDestination(
        for attachment: QuickAssistantAttachment,
        format: AssistantConversionFormat
    ) -> URL? {
        if QuickAssistantFileConverter.needsDestinationFolder(source: attachment.url, format: format) {
            let panel = NSOpenPanel()
            panel.title = "Choose a Folder for Converted Pages"
            panel.prompt = "Convert Here"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        }

        let panel = NSSavePanel()
        panel.title = "Save Converted File"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = attachment.url
            .deletingPathExtension()
            .lastPathComponent + "." + format.fileExtension
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseBatchConversionFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for Converted Files"
        panel.prompt = "Convert Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseArchiveDestination(for files: [URL]) -> URL? {
        let suggested = QuickAssistantOutputActions.automaticArchiveURL(for: files)
        let panel = NSSavePanel()
        panel.title = "Save ZIP Archive"
        panel.prompt = "Compress"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            presentResponse(QuickAssistantOutputActions.OutputActionError.destinationExists.localizedDescription)
            return nil
        }
        return destination
    }

    private func compressConvertedFiles(to destination: URL) {
        let files = convertedFiles
        isConverting = true
        response = "Compressing \(files.count) converted file(s)…"
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { isConverting = false }
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    try QuickAssistantOutputActions.compress(files, to: destination)
                }.value
                convertedFiles.append(archive)
                presentResponse("Created \(archive.lastPathComponent).")
            } catch {
                presentResponse("Compression failed. \(error.localizedDescription)")
            }
            focusRequest += 1
        }
    }

    private func runAutomaticOutputAction() async throws {
        switch automaticOutputAction {
        case .none:
            return
        case .reveal:
            revealConvertedFiles()
            response += " Revealed in Finder."
        case .copy:
            if copyOutputsToClipboard() { response += " Copied to the clipboard." }
        case .compress:
            let files = convertedFiles
            let destination = QuickAssistantOutputActions.automaticArchiveURL(for: files)
            let archive = try await Task.detached(priority: .userInitiated) {
                try QuickAssistantOutputActions.compress(files, to: destination)
            }.value
            convertedFiles.append(archive)
            response += " Compressed outputs to \(archive.lastPathComponent)."
        }
    }

    private func copyOutputsToClipboard() -> Bool {
        guard !convertedFiles.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects(convertedFiles.map { $0 as NSURL })
    }

    private func requestModelResponse(
        for request: String,
        history: [QuickAssistantMessage],
        replacing messageID: UUID? = nil
    ) {
        guard SystemLanguageModel.default.isAvailable else {
            presentResponse("Apple Intelligence is unavailable on this Mac.", replacing: messageID)
            return
        }

        isWorking = true
        response = ""
        let contextualRequest = contextualRequest(for: request)
        let historyBudget = max(
            0,
            min(
                Self.maximumTranscriptCharacters,
                12_000 - contextualRequest.prompt.count
            )
        )
        let session = Self.makeSession(from: history, maximumCharacters: historyBudget)
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }
            do {
                let result = try await session.respond(to: contextualRequest.prompt)
                guard !Task.isCancelled else { return }
                presentResponse(
                    result.content.trimmingCharacters(in: .whitespacesAndNewlines),
                    context: contextualRequest.context,
                    allowsRetry: true,
                    replacing: messageID
                )
            } catch is CancellationError {
                return
            } catch {
                presentResponse(
                    "I couldn’t answer that right now. \(error.localizedDescription)",
                    context: contextualRequest.context,
                    allowsRetry: true,
                    replacing: messageID
                )
            }
        }
    }

    private static func makeSession(
        from history: [QuickAssistantMessage],
        maximumCharacters: Int
    ) -> LanguageModelSession {
        var completedTurns: [(user: String, assistant: String)] = []
        var pendingUserText: String?
        for message in history {
            switch message.role {
            case .user:
                pendingUserText = message.text
            case .assistant:
                guard let userText = pendingUserText else { continue }
                completedTurns.append((userText, message.text))
                pendingUserText = nil
            }
        }

        var remainingCharacters = maximumCharacters
        var selectedTurns: [(user: String, assistant: String)] = []
        for turn in completedTurns.reversed() where remainingCharacters > 0 {
            let turnLength = turn.user.count + turn.assistant.count
            if turnLength <= remainingCharacters {
                selectedTurns.append(turn)
                remainingCharacters -= turnLength
                continue
            }

            guard selectedTurns.isEmpty, remainingCharacters >= 2 else { break }
            let userBudget = min(turn.user.count, max(1, remainingCharacters / 3))
            let assistantBudget = max(1, remainingCharacters - userBudget)
            selectedTurns.append(
                (
                    String(turn.user.prefix(userBudget)),
                    String(turn.assistant.prefix(assistantBudget))
                )
            )
            break
        }

        var entries: [Transcript.Entry] = [
            .instructions(
                .init(
                    segments: [.text(.init(content: modelInstructions))],
                    toolDefinitions: []
                )
            )
        ]
        for turn in selectedTurns.reversed() {
            entries.append(
                .prompt(
                    .init(
                        segments: [.text(.init(content: turn.user))]
                    )
                )
            )
            entries.append(
                .response(
                    .init(
                        assetIDs: [],
                        segments: [.text(.init(content: turn.assistant))]
                    )
                )
            )
        }
        return LanguageModelSession(transcript: Transcript(entries: entries))
    }

    private func appendMessage(
        role: QuickAssistantMessageRole,
        text: String,
        context: [QuickAssistantContextChip] = [],
        allowsRetry: Bool = false
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(
            QuickAssistantMessage(
                role: role,
                text: trimmed,
                context: context,
                allowsRetry: allowsRetry
            )
        )
        if messages.count > Self.maximumSavedMessages {
            messages.removeFirst(messages.count - Self.maximumSavedMessages)
        }
        persistMessages()
    }

    private func presentResponse(
        _ text: String,
        context: [QuickAssistantContextChip] = [],
        allowsRetry: Bool = false,
        replacing messageID: UUID? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        response = trimmed

        if let messageID,
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].text = trimmed
            messages[index].context = context
            messages[index].allowsRetry = allowsRetry
            persistMessages()
            return
        }

        if messages.last?.role == .assistant, messages.last?.text == trimmed { return }
        appendMessage(
            role: .assistant,
            text: trimmed,
            context: context,
            allowsRetry: allowsRetry
        )
    }

    private func persistMessages() {
        guard savesConversationHistory else { return }
        let messagesToSave = messages.suffix(Self.maximumSavedMessages).map { message in
            var savedMessage = message
            savedMessage.text = String(
                savedMessage.text.prefix(Self.maximumSavedMessageCharacters)
            )
            return savedMessage
        }
        guard let data = try? JSONEncoder().encode(messagesToSave) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedMessagesKey)
    }

    private struct ContextualRequest {
        let prompt: String
        let context: [QuickAssistantContextChip]
    }

    private func contextualRequest(for request: String) -> ContextualRequest {
        var context: [String] = []
        var chips: [QuickAssistantContextChip] = []
        if let track = spotify.nowPlaying {
            context.append("Current Spotify track: \(track.title) by \(track.artist); playback is \(track.isPlaying ? "playing" : "paused").")
            chips.append(.init(label: "Spotify", systemImage: "music.note"))
        }
        if let lyric = lyrics.currentLine?.text, !lyric.isEmpty {
            context.append("Current lyric: \(lyric)")
            chips.append(.init(label: "Current lyric", systemImage: "quote.bubble"))
        }

        if request.lowercased().contains("clipboard"),
           let clipboard = NSPasteboard.general.string(forType: .string),
           !clipboard.isEmpty {
            context.append("Clipboard text:\n\(String(clipboard.prefix(8_000)))")
            chips.append(.init(label: "Clipboard", systemImage: "clipboard"))
        }

        if !attachments.isEmpty {
            context.append("Attached files: \(attachments.map { "\($0.name) (\($0.typeName))" }.joined(separator: ", ")).")
            for attachment in attachments.prefix(3) {
                chips.append(.init(label: attachment.name, systemImage: "paperclip"))
            }
            if attachments.count > 3 {
                chips.append(.init(label: "+\(attachments.count - 3) files", systemImage: "doc.on.doc"))
            }
            let readableText = attachments
                .filter(\.hasReadableText)
                .map { "File: \($0.name)\n\($0.extractedText)" }
                .joined(separator: "\n\n")
            if readableText.isEmpty {
                context.append("No readable text was extracted from the attached files. Be transparent about that limitation.")
            } else {
                context.append("Extracted file text:\n\(String(readableText.prefix(12_000)))")
            }
        }

        let prompt = context.isEmpty
            ? request
            : "\(context.joined(separator: "\n"))\n\nUser request: \(request)"
        return ContextualRequest(prompt: prompt, context: chips)
    }
}

enum AssistantFileAnalyzer {
    private static let maximumTextCharacters = 40_000
    private static let maximumPDFPages = 20
    private static let maximumOCRPages = 5

    static func analyze(_ url: URL) async throws -> QuickAssistantAttachment {
        let hasSecurityAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw FileAnalysisError.notAFile }
        let type = QuickAssistantFileConverter.detectedContentType(for: url)

        if type?.conforms(to: .pdf) == true {
            let text = try await textFromPDF(url)
            return QuickAssistantAttachment(url: url, typeName: "PDF", extractedText: limited(text))
        }
        if type?.conforms(to: .image) == true {
            let text = try await recognizeText(in: url)
            return QuickAssistantAttachment(url: url, typeName: type?.localizedDescription ?? "Image", extractedText: limited(text))
        }
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let prefix = Data(data.prefix(2_000_000))
            let text = String(data: prefix, encoding: .utf8)
                ?? String(data: prefix, encoding: .utf16)
                ?? ""
            return QuickAssistantAttachment(url: url, typeName: type?.localizedDescription ?? "Text", extractedText: limited(text))
        }
        if type?.conforms(to: .audio) == true {
            return QuickAssistantAttachment(url: url, typeName: "Audio", extractedText: "")
        }

        throw FileAnalysisError.unsupportedType
    }

    private static func textFromPDF(_ url: URL) async throws -> String {
        guard let document = PDFDocument(url: url) else { throw FileAnalysisError.unreadablePDF }
        let pageCount = min(document.pageCount, maximumPDFPages)
        var pageTexts: [String] = []

        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let embeddedText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !embeddedText.isEmpty {
                pageTexts.append("Page \(index + 1):\n\(embeddedText)")
            } else if index < maximumOCRPages,
                      let image = cgImage(for: page) {
                let recognized = try await recognizeText(in: image)
                if !recognized.isEmpty {
                    pageTexts.append("Page \(index + 1):\n\(recognized)")
                }
            }
        }
        return pageTexts.joined(separator: "\n\n")
    }

    private static func cgImage(for page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let targetWidth: CGFloat = 1_800
        let scale = targetWidth / max(bounds.width, 1)
        let image = page.thumbnail(
            of: NSSize(width: targetWidth, height: max(bounds.height * scale, 1)),
            for: .mediaBox
        )
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private static func recognizeText(in url: URL) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: url)
        return recognizedLines(from: observations)
    }

    private static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        return recognizedLines(from: observations)
    }

    private static func recognizedLines(from observations: [RecognizedTextObservation]) -> String {
        observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func limited(_ text: String) -> String {
        String(text.prefix(maximumTextCharacters))
    }

    private enum FileAnalysisError: LocalizedError {
        case notAFile
        case unsupportedType
        case unreadablePDF

        var errorDescription: String? {
            switch self {
            case .notAFile: return "The dropped item is not a regular file."
            case .unsupportedType: return "Use a PDF, image, audio, plain-text, or source-code file."
            case .unreadablePDF: return "The PDF could not be opened."
            }
        }
    }
}
