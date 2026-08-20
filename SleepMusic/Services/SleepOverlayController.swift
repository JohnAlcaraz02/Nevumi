import AppKit
import SwiftUI

/// Presents a fullscreen, borderless window showing the current lyric line —
/// the "screen while the Mac sleeps" surface.
///
/// This is our own top-level window at screen-saver window level, not an
/// injection into the real system lock screen (that surface is SIP-protected
/// and off-limits to normal apps). It shows on top of the desktop when Sleep
/// Mode is entered manually, or automatically while a track is playing and
/// the screen locks — the same client-side trick lock-screen widget apps use:
/// listen for the lock/unlock distributed notifications and race to paint
/// before the system lock UI settles. It closes on any key press or click.
@MainActor
final class SleepOverlayController: NSObject {
    static let shared = SleepOverlayController()

    private var window: NSWindow?
    private var eventMonitor: Any?
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?

    func show(trackTitle: String, lyrics: LyricsViewModel) {
        guard window == nil, let screen = NSScreen.main else { return }

        let panel = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: SleepOverlayView(trackTitle: trackTitle, lyrics: lyrics, onDismiss: { [weak self] in self?.hide() })
        )
        panel.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        window = panel

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.hide()
            return event
        }
    }

    func hide() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        window?.orderOut(nil)
        window = nil
    }

    /// Auto-shows the overlay when the screen locks while a track is
    /// playing, and hides it on unlock. Call once at app launch.
    func observeLockEvents(lyrics: LyricsViewModel, isPlaying: @escaping () -> Bool, trackTitle: @escaping () -> String) {
        let center = DistributedNotificationCenter.default()

        lockObserver = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard isPlaying() else { return }
                self?.show(trackTitle: trackTitle(), lyrics: lyrics)
            }
        }

        unlockObserver = center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }
}
