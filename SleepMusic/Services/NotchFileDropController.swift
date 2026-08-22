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
    private var isExpanded = false

    private override init() {
        super.init()
    }

    func start() {
        createPanelIfNeeded()
    }

    private func createPanelIfNeeded() {
        guard panel == nil else {
            positionPanel(animated: false)
            panel?.orderFrontRegardless()
            return
        }

        guard let screen = notchScreen else { return }
        let size = panelSize(on: screen)
        let initialFrame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
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
        // DynamicNotchKit presents the music player at `.screenSaver`. Keep
        // this thin receiver one level above it so Finder drops still reach
        // the app while the player is visible.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onFileDrop = { [weak self] urls in
            self?.receive(urls)
        }
        panel.onTargetingChanged = { [weak self] isTargeted, fileName in
            self?.state.isTargeted = isTargeted
            self?.state.fileName = fileName
            self?.setExpanded(isTargeted)
        }
        panel.contentView = NSHostingView(rootView: NotchFileDropFeedback(state: state))
        self.panel = panel

        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionPanel(animated: false) }
        }
    }

    private func receive(_ urls: [URL]) {
        setExpanded(false)
        QuickAssistantWindowController.shared.show(attaching: urls)
    }

    private func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        positionPanel(animated: true)
    }

    private func positionPanel(animated: Bool) {
        guard let panel, let screen = notchScreen else { return }
        let size = panelSize(on: screen)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
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

    private func panelSize(on screen: NSScreen) -> NSSize {
        if isExpanded {
            return NSSize(width: 350, height: 88)
        }

        let physicalNotchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            physicalNotchWidth = right.minX - left.maxX
        } else {
            physicalNotchWidth = 210
        }

        return NSSize(
            // The camera cutout itself does not report pointer events. Extend
            // beyond it so the receiver includes the visible strip directly
            // below and beside the physical notch.
            width: min(max(physicalNotchWidth + 80, 260), 340),
            height: max(screen.safeAreaInsets.top + 20, 52)
        )
    }
}

private final class NotchFileDropPanel: NSPanel {
    var onFileDrop: (([URL]) -> Void)?
    var onTargetingChanged: ((Bool, String?) -> Void)?

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        // Register the window itself. A transparent hosting view is not a
        // dependable dragging destination when the drag originates in Finder.
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let urls = supportedFileURLs(from: sender) else {
            onTargetingChanged?(false, nil)
            return []
        }
        onTargetingChanged?(true, label(for: urls))
        return .copy
    }

    @objc func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let urls = supportedFileURLs(from: sender) else { return [] }
        onTargetingChanged?(true, label(for: urls))
        return .copy
    }

    @objc func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetingChanged?(false, nil)
    }

    @objc func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        supportedFileURLs(from: sender) != nil
    }

    @objc func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = supportedFileURLs(from: sender) else {
            onTargetingChanged?(false, nil)
            return false
        }
        onTargetingChanged?(false, nil)
        onFileDrop?(urls)
        return true
    }

    @objc func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onTargetingChanged?(false, nil)
    }

    private func supportedFileURLs(from sender: any NSDraggingInfo) -> [URL]? {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return nil
        }
        let supported = urls.filter(Self.supports)
        return supported.isEmpty ? nil : supported
    }

    private func label(for urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
    }

    private static func supports(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return false
        }
        return !QuickAssistantFileConverter.availableFormats(for: url).isEmpty
    }
}

@MainActor
private final class NotchFileDropState: ObservableObject {
    @Published var isTargeted = false
    @Published var fileName: String?
}

private struct NotchFileDropFeedback: View {
    @ObservedObject var state: NotchFileDropState

    var body: some View {
        ZStack {
            Color.clear

            if state.isTargeted {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop to convert")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        if let fileName = state.fileName {
                            Text(fileName)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(Color.black)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: 22,
                        bottomTrailingRadius: 22
                    )
                )
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(.green.opacity(0.85))
                        .frame(width: 54, height: 2)
                        .padding(.bottom, 7)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: state.isTargeted)
    }
}
