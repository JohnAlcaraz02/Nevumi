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
    @Published private(set) var isWorking = false
    @Published private(set) var focusRequest = 0
    @Published private(set) var attachments: [QuickAssistantAttachment] = []
    @Published private(set) var isAnalyzingAttachment = false
    @Published private(set) var isConverting = false
    @Published private(set) var isRemovingBackground = false
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
    private lazy var session = LanguageModelSession(
        instructions: """
        You are the concise personal assistant inside a small Mac notch panel.
        Answer in plain text using at most four short sentences unless the user
        explicitly asks for detail. Never claim that you performed an action.
        Music and Sleep Mode actions are handled separately by the app.
        """
    )

    init(spotify: SpotifyObserver, lyrics: LyricsViewModel) {
        self.spotify = spotify
        self.lyrics = lyrics
        if let stored = UserDefaults.standard.string(forKey: "assistantAutomaticOutputAction"),
           let action = AssistantAutomaticOutputAction(rawValue: stored) {
            automaticOutputAction = action
        }
    }

    var attachment: QuickAssistantAttachment? { attachments.first }

    deinit {
        requestTask?.cancel()
    }

    func prepareForPresentation() {
        focusRequest += 1
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
                response = "Added “\(entry.title)” to \(calendarName) for \(dateDescription)."
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
                response = "I couldn’t attach those files. \(failures.first ?? "No supported files were found.")"
            } else if analyzedFiles.count == 1 {
                let analyzed = analyzedFiles[0]
                if QuickAssistantFileConverter.detectedContentType(for: analyzed.url)?.conforms(to: .audio) == true {
                    response = "\(analyzed.name) is ready. Choose WAV, AIFF, or CAF from Convert."
                } else {
                    response = analyzed.hasReadableText
                        ? "\(analyzed.name) is ready. Ask a question or choose an action below."
                        : "I attached \(analyzed.name), but couldn’t find readable text in it."
                }
            } else {
                let skipped = failures.isEmpty ? "" : " \(failures.count) unsupported file(s) were skipped."
                response = "\(analyzedFiles.count) files are ready for analysis or batch conversion.\(skipped)"
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
              !isEnhancingImage,
              !isSavingCalendarEntry,
              !isAnalyzingAttachment else { return }

        query = ""
        requestTask?.cancel()

        if handleConversionCommand(request) { return }

        if let localResponse = performLocalCommand(request) {
            response = localResponse
            return
        }

        guard SystemLanguageModel.default.isAvailable else {
            response = "Apple Intelligence is unavailable on this Mac. You can still say “play or pause,” “next song,” “previous song,” “what song is playing,” or “enter sleep mode.”"
            return
        }

        isWorking = true
        response = ""
        let prompt = contextualPrompt(for: request)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.respond(to: prompt)
                guard !Task.isCancelled else { return }
                response = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch is CancellationError {
                return
            } catch {
                response = "I couldn’t answer that right now. \(error.localizedDescription)"
            }
            isWorking = false
        }
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
            response = "Attach a file before converting it."
            return
        }
        guard availableConversionFormats.contains(format) else {
            response = "\(format.displayName) isn’t available for this file type."
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
            } catch is CancellationError {
                return
            } catch {
                response = "Conversion failed. \(error.localizedDescription)"
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

    func editImageAttachment() {
        guard let attachment = attachments.first else {
            response = "Drop an image here first, then I can open the editor."
            return
        }
        guard canEditImage else {
            response = "The image editor works with image files only."
            return
        }

        do {
            try QuickAssistantImageEditorController.shared.present(
                source: attachment.url
            ) { [weak self] output in
                guard let self else { return }
                convertedFiles = [output]
                response = "Saved the edited image as \(output.lastPathComponent)."
                focusRequest += 1
            }
            response = "Opened \(attachment.name) in the offline image editor."
        } catch {
            response = "Couldn’t open the image editor. \(error.localizedDescription)"
        }
    }

    func enhanceImageAttachment() {
        guard let attachment = attachments.first else {
            response = "Drop an image here first, then I can enhance it."
            return
        }
        guard canEnhanceImage else {
            response = "Photo enhancement works with image files only."
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
            } catch is CancellationError {
                return
            } catch {
                response = "Couldn’t enhance the photo. \(error.localizedDescription)"
            }
            focusRequest += 1
        }
    }

    func removeBackgroundFromAttachment() {
        guard let attachment = attachments.first else {
            response = "Drop an image here first, then I can remove its background."
            return
        }
        guard canRemoveBackground else {
            response = "Removing backgrounds works with image files only."
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
            } catch is CancellationError {
                return
            } catch {
                response = "Couldn’t remove the background. \(error.localizedDescription)"
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
        response = action == .none
            ? "Automatic output actions are off."
            : "After conversion, SleepMusic will \(action.displayName.lowercased())."
    }

    func copyConvertedFiles() {
        guard copyOutputsToClipboard() else {
            response = "There are no converted files to copy."
            return
        }
        response = convertedFiles.count == 1
            ? "Copied the converted file to the clipboard."
            : "Copied \(convertedFiles.count) converted files to the clipboard."
    }

    func compressConvertedFiles() {
        guard !convertedFiles.isEmpty else {
            response = "There are no converted files to compress."
            return
        }
        guard let destination = chooseArchiveDestination(for: convertedFiles) else { return }
        compressConvertedFiles(to: destination)
    }

    func renameConvertedFile() {
        guard convertedFiles.count == 1, let source = convertedFiles.first else {
            response = "Rename is available when there is exactly one converted file."
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
            response = QuickAssistantOutputActions.OutputActionError.destinationExists.localizedDescription
            return
        }

        do {
            try FileManager.default.moveItem(at: source, to: destination)
            convertedFiles = [destination]
            response = "Renamed the converted file to \(destination.lastPathComponent)."
        } catch {
            response = "Rename failed. \(error.localizedDescription)"
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
            return "Ask a question, add calendar notes, or drop files to analyze and convert. For images I can open an offline editor, enhance the photo, erase objects, replace or remove the background. I can also summarize clipboard text, control Spotify, check the current song, and enter Sleep Mode."
        }
        return nil
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
            response = "Drop or attach a file before asking me to convert it."
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
            response = "Choose an output format from the Convert menu."
            return true
        }

        guard let requestedFormat, availableConversionFormats.contains(requestedFormat) else {
            response = "That output format isn’t available for the attached file."
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
            response = QuickAssistantOutputActions.OutputActionError.destinationExists.localizedDescription
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
                response = "Created \(archive.lastPathComponent)."
            } catch {
                response = "Compression failed. \(error.localizedDescription)"
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

    private func contextualPrompt(for request: String) -> String {
        var context: [String] = []
        if let track = spotify.nowPlaying {
            context.append("Current Spotify track: \(track.title) by \(track.artist); playback is \(track.isPlaying ? "playing" : "paused").")
        }
        if let lyric = lyrics.currentLine?.text, !lyric.isEmpty {
            context.append("Current lyric: \(lyric)")
        }

        if request.lowercased().contains("clipboard"),
           let clipboard = NSPasteboard.general.string(forType: .string),
           !clipboard.isEmpty {
            context.append("Clipboard text:\n\(String(clipboard.prefix(8_000)))")
        }

        if !attachments.isEmpty {
            context.append("Attached files: \(attachments.map { "\($0.name) (\($0.typeName))" }.joined(separator: ", ")).")
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

        if context.isEmpty { return request }
        return "\(context.joined(separator: "\n"))\n\nUser request: \(request)"
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
