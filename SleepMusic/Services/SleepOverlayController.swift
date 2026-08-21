import AppKit
import SwiftUI

/// Presents a fullscreen, borderless window showing the current lyric line —
/// the "screen while the Mac sleeps" surface.
///
/// This is our own top-level window at screen-saver window level, not an
/// injection into the real system lock screen (that surface is rendered by
/// loginwindow, a secure system process no ordinary app can draw above —
/// by design, so nothing can fake a password prompt). It shows on top of
/// the desktop when Sleep Mode is entered manually, or automatically while
/// a track is playing and the screen locks (works immediately if this Mac
/// doesn't require a password) or right after a real password-protected
/// unlock (a "welcome back" moment, since we can't cover the password
/// prompt itself). It closes on any key press or click.
@MainActor
final class SleepOverlayController: NSObject {
    static let shared = SleepOverlayController()

    private var window: NSWindow?
    private var eventMonitor: Any?
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func show(spotify: SpotifyObserver, lyrics: LyricsViewModel) {
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
            rootView: SleepOverlayView(spotify: spotify, lyrics: lyrics, onDismiss: { [weak self] in self?.hide() })
        )
        panel.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        window = panel
        NotchController.shared.bringToFront()

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

    /// Auto-shows the overlay while a track is playing: immediately when the
    /// screen locks or the Mac sleeps (best-effort — only actually visible
    /// if this Mac doesn't require a password to wake), and again, freshly,
    /// right after a real unlock — since a password-protected wake can't be
    /// covered, this is the moment we *can* still greet the user. Call once
    /// at app launch.
    func observeLockEvents(spotify: SpotifyObserver, lyrics: LyricsViewModel, isPlaying: @escaping () -> Bool) {
        let distributedCenter = DistributedNotificationCenter.default()
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        lockObserver = distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard isPlaying() else { return }
                self?.show(spotify: spotify, lyrics: lyrics)
            }
        }
        unlockObserver = distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard isPlaying() else { return }
                self?.hide()
                self?.show(spotify: spotify, lyrics: lyrics)
            }
        }
        sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard isPlaying() else { return }
                self?.show(spotify: spotify, lyrics: lyrics)
            }
        }
        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Clears any pre-sleep window right as the (possibly
            // password-protected) lock screen appears, so stale state
            // doesn't linger behind it — the real re-show happens on
            // screenIsUnlocked once the user actually gets back in.
            Task { @MainActor in self?.hide() }
        }
    }
}
