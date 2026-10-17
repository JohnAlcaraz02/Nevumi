import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps a small drag destination over the physical camera notch. The window
/// is visually transparent during normal use and only grows into a visible
/// shelf while Finder is dragging a supported file over it.
@MainActor
final class NotchFileDropController: NSObject {
    static let shared = NotchFileDropController()

    private let state = NotchFileDropState()
    private var panel: NotchFileDropPanel?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var isExpanded = false

    private override init() {
        super.init()
    }

    func start() {
        createPanelIfNeeded()
        if panel == nil {
            print("[NotchDrop] no notch screen yet at start=\(NSScreen.screens.count) screens; will retry on screen changes")
        }
    }

    private func createPanelIfNeeded() {
        guard panel == nil else {
            positionPanel(animated: false)
            panel?.refreshDraggingRegistration()
            panel?.orderFrontRegardless()
            return
        }

        guard let screen = notchScreen else { return }
        let size = panelSize(on: screen)
        let initialFrame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - screen.safeAreaInsets.top - size.height,
            width: size.width,
            height: size.height
        )

        let panel = NotchFileDropPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Very high window levels are excluded from Finder's drag routing,
        // so this invisible receiver stays at a proven destination level.
        // Visible feedback is rendered by the music player's notch window.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let dropView = NotchFileDropDestinationView(state: state)
        dropView.onFileDrop = { [weak self] urls, action in
            self?.receive(urls, action: action)
        }
        dropView.onTargetingChanged = { [weak self] isTargeted, fileName, action in
            self?.state.isTargeted = isTargeted
            self?.state.fileName = fileName
            self?.setExpanded(isTargeted, action: action)
        }
        panel.contentView = dropView
        self.panel = panel

        panel.orderFrontRegardless()
        print("[NotchDrop] panel ready frame=\(panel.frame) level=\(panel.level.rawValue) screen=\(screen.localizedName) topInset=\(screen.safeAreaInsets.top) occlusion=\(panel.occlusionState.rawValue)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak panel] in
            guard let panel else { return }
            print("[NotchDrop] occlusion settled=\(panel.occlusionState.rawValue) visible=\(panel.occlusionState.contains(.visible))")
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPanel() }
        }

        // AppKit can discard a drag destination's registration while the
        // display server is torn down for sleep. Re-register when the Mac
        // wakes and whenever the app becomes active again.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPanel() }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPanel() }
        }
    }

    private func refreshPanel() {
        createPanelIfNeeded()
        positionPanel(animated: false)
        panel?.refreshDraggingRegistration()
        panel?.orderFrontRegardless()
    }

    private func receive(_ urls: [URL], action: NotchDropAction) {
        setExpanded(false)
        switch action {
        case .convert:
            NotchConvertCardController.shared.present(files: urls)
        case .airDrop:
            AirDropSharingService.shared.share(urls)
        }
    }

    private func setExpanded(_ expanded: Bool, action: NotchDropAction = .convert) {
        NotchController.shared.setFileDropTargeted(
            expanded,
            fileName: expanded ? state.fileName : nil,
            action: action
        )
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        positionPanel(animated: true)
    }

    private func positionPanel(animated: Bool) {
        guard let panel, let screen = notchScreen else { return }
        let size = panelSize(on: screen)
        let originY = isExpanded
            ? screen.frame.maxY - size.height
            : screen.frame.maxY - screen.safeAreaInsets.top - size.height
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: originY,
            width: size.width,
            height: size.height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private var notchScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Idle, the invisible receiver is a tiny strip below the physical notch.
    /// During a drag it grows beneath the music player's expanded footprint.
    private func panelSize(on screen: NSScreen) -> NSSize {
        if isExpanded {
            return NSSize(width: 340, height: 160)
        }

        let physicalNotchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            physicalNotchWidth = right.minX - left.maxX
        } else {
            physicalNotchWidth = 200
        }

        return NSSize(width: max(physicalNotchWidth - 12, 140), height: 22)
    }
}

private final class NotchFileDropPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func refreshDraggingRegistration() {
        (contentView as? NotchFileDropDestinationView)?.refreshDraggingRegistration()
    }
}

/// A native AppKit destination is used instead of relying on a completely
/// transparent SwiftUI hierarchy. Finder sends dragging callbacks directly to
/// this registered view, while the hosting view remains responsible for the
/// visual feedback.
private final class NotchFileDropDestinationView: NSView {
    var onFileDrop: (([URL], NotchDropAction) -> Void)?
    var onTargetingChanged: ((Bool, String?, NotchDropAction) -> Void)?

    private var isDragSessionActive = false

    /// Lets clicks fall through to whatever is underneath while idle, yet
    /// keeps the view hittable for an active drag session.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isDragSessionActive ? self : nil
    }

    init(state: NotchFileDropState) {
        super.init(frame: .zero)

        wantsLayer = true
        // A tiny non-zero alpha keeps this window in the WindowServer's
        // composited surface list without making the receiver visible.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor

        let hostingView = NSHostingView(rootView: NotchFileDropFeedback())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        refreshDraggingRegistration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshDraggingRegistration() {
        unregisterDraggedTypes()
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = supportedFileURLs(from: sender)
        print("[NotchDrop] draggingEntered urls=\(urls?.map(\.lastPathComponent) ?? [])")
        guard let urls else {
            onTargetingChanged?(false, nil, .convert)
            return []
        }
        isDragSessionActive = true
        onTargetingChanged?(true, label(for: urls), dropAction(at: sender))
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let urls = supportedFileURLs(from: sender) else { return [] }
        isDragSessionActive = true
        onTargetingChanged?(true, label(for: urls), dropAction(at: sender))
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDragSessionActive = false
        onTargetingChanged?(false, nil, .convert)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        supportedFileURLs(from: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = supportedFileURLs(from: sender) else {
            onTargetingChanged?(false, nil, .convert)
            return false
        }
        let action = dropAction(at: sender)
        onTargetingChanged?(false, nil, action)
        onFileDrop?(urls, action)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        isDragSessionActive = false
        onTargetingChanged?(false, nil, .convert)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        isDragSessionActive = false
        onTargetingChanged?(false, nil, .convert)
    }

    /// The receiver is split in half: the left side converts, the right side
    /// shares via AirDrop. The notch card mirrors this split.
    private func dropAction(at sender: any NSDraggingInfo) -> NotchDropAction {
        let point = convert(sender.draggingLocation, from: nil)
        return point.x < bounds.midX ? .convert : .airDrop
    }

    private func supportedFileURLs(from sender: any NSDraggingInfo) -> [URL]? {
        let pasteboard = sender.draggingPasteboard
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []

        var urls = objects.compactMap { object -> URL? in
            guard let url = object as? NSURL else { return nil }
            return url as URL
        }

        // Older Finder drags can expose only the legacy filename list.
        if urls.isEmpty,
           let paths = pasteboard.propertyList(
               forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
           ) as? [String] {
            urls = paths.map(URL.init(fileURLWithPath:))
        }

        var seen = Set<URL>()
        let files = urls
            .map(\.standardizedFileURL)
            .filter(\.isFileURL)
            .filter { seen.insert($0).inserted }
        // AirDrop accepts anything; conversion stays restricted to formats
        // the converter understands.
        let action = dropAction(at: sender)
        switch action {
        case .airDrop:
            return files.isEmpty ? nil : files
        case .convert:
            let supported = files.filter(Self.supportsConversion)
            return supported.isEmpty ? nil : supported
        }
    }

    private func label(for urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
    }

    private static func supportsConversion(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory != true else { return false }
        return !QuickAssistantFileConverter.availableFormats(for: url).isEmpty
    }
}

@MainActor
private final class NotchFileDropState: ObservableObject {
    @Published var isTargeted = false
    @Published var fileName: String?
}

private struct NotchFileDropFeedback: View {
    var body: some View {
        // The receiver remains composited for drag routing, while all visible
        // feedback is rendered by the music player's DynamicNotch.
        Color.black.opacity(0.001)
            .accessibilityHidden(true)
    }
}
