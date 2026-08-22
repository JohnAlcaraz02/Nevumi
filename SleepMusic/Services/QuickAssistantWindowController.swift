import AppKit
import SwiftUI

private final class QuickAssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickAssistantWindowController: NSObject, NSWindowDelegate {
    static let shared = QuickAssistantWindowController()

    private var panel: NSPanel?
    private var viewModel: QuickAssistantViewModel?
    private var escapeMonitor: Any?

    func configure(spotify: SpotifyObserver, lyrics: LyricsViewModel) {
        guard viewModel == nil else { return }
        viewModel = QuickAssistantViewModel(spotify: spotify, lyrics: lyrics)
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let viewModel else { return }
        let panel = panel ?? makePanel(viewModel: viewModel)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewModel.prepareForPresentation()
        installEscapeMonitor()
    }

    /// Presents the assistant after a file is released on the physical notch
    /// and immediately begins its normal local attachment analysis.
    func show(attaching url: URL) {
        show(attaching: [url])
    }

    func show(attaching urls: [URL]) {
        show()
        viewModel?.attachFiles(urls)
    }

    func hide() {
        panel?.orderOut(nil)
        removeEscapeMonitor()
    }

    private func makePanel(viewModel: QuickAssistantViewModel) -> NSPanel {
        let size = NSSize(width: 540, height: 390)
        let panel = QuickAssistantPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: QuickAssistantView(viewModel: viewModel, onClose: { [weak self] in self?.hide() })
        )
        panel.delegate = self
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - frame.width / 2,
            y: screen.visibleFrame.maxY - frame.height - 10
        ))
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.hide()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
