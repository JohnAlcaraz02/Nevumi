import AppKit
import Combine
import SkyLightWindow
import SwiftUI

/// Presents a fullscreen, borderless window showing the current lyric line —
/// the "screen while the Mac sleeps" surface.
///
/// This is our own top-level window at screen-saver window level, not an
/// injection into the secure password UI rendered by loginwindow. In manual
/// Sleep Mode it is interactive and closes on a key press or click. While
/// the Mac is locked it becomes a click-through, non-key window that remains
/// eligible for display without a logged-in desktop and temporarily prevents
/// idle display/system sleep while Spotify is playing.
@MainActor
final class SleepOverlayController: NSObject {
    static let shared = SleepOverlayController()

    private enum PresentationMode {
        case manual
        case lockScreen
    }

    private var window: NSWindow?
    private var eventMonitor: Any?
    private var lockScreenActivity: NSObjectProtocol?
    private var playbackCancellable: AnyCancellable?
    private var isDelegatedToLockScreen = false
    private var isScreenLocked = false
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func show(spotify: SpotifyObserver, lyrics: LyricsViewModel) {
        present(spotify: spotify, lyrics: lyrics, mode: .manual)
    }

    private func present(
        spotify: SpotifyObserver,
        lyrics: LyricsViewModel,
        mode: PresentationMode
    ) {
        if let window {
            if mode == .manual, isDelegatedToLockScreen {
                hide()
                present(spotify: spotify, lyrics: lyrics, mode: mode)
                return
            }
            configure(window: window, for: mode)
            return
        }

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
        panel.canBecomeVisibleWithoutLogin = mode == .lockScreen
        panel.contentView = NSHostingView(
            rootView: SleepOverlayView(spotify: spotify, lyrics: lyrics, onDismiss: { [weak self] in self?.hide() })
        )
        window = panel
        configure(window: panel, for: mode)
    }

    private func configure(window: NSWindow, for mode: PresentationMode) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        switch mode {
        case .manual:
            endLockScreenActivity()
            window.canBecomeVisibleWithoutLogin = false
            window.ignoresMouseEvents = false
            window.makeKeyAndOrderFront(nil)
            NSCursor.setHiddenUntilMouseMoves(true)
            NotchController.shared.bringToFront()

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.hide()
                return event
            }
        case .lockScreen:
            beginLockScreenActivity()
            window.canBecomeVisibleWithoutLogin = true
            window.ignoresMouseEvents = true
            if !isDelegatedToLockScreen {
                SkyLightOperator.shared.delegateWindow(window)
                isDelegatedToLockScreen = true
            }
            window.orderFrontRegardless()
        }
    }

    func hide() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        window?.orderOut(nil)
        window = nil
        isDelegatedToLockScreen = false
        endLockScreenActivity()
    }

    /// Auto-shows a click-through overlay while the screen is locked and a
    /// track is playing. The accompanying power activity prevents idle sleep,
    /// but forced sleep (lid close, Apple menu, or low battery) is respected.
    /// Call once at app launch.
    func observeLockEvents(spotify: SpotifyObserver, lyrics: LyricsViewModel, isPlaying: @escaping () -> Bool) {
        let distributedCenter = DistributedNotificationCenter.default()
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        playbackCancellable = spotify.$nowPlaying
            .map { $0?.isPlaying == true }
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                Task { @MainActor in
                    guard let self, self.isScreenLocked else { return }
                    if isPlaying {
                        self.present(spotify: spotify, lyrics: lyrics, mode: .lockScreen)
                    } else {
                        self.hide()
                    }
                }
            }

        lockObserver = distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = true
                guard isPlaying() else { return }
                self?.present(spotify: spotify, lyrics: lyrics, mode: .lockScreen)
            }
        }
        unlockObserver = distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = false
                self?.hide()
            }
        }
        sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // A lid close, explicit Sleep command, or power emergency may
            // force sleep despite the idle-sleep activity. Release all UI
            // and power resources before suspension.
            Task { @MainActor in self?.hide() }
        }
        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isScreenLocked, isPlaying() else { return }
                self.present(spotify: spotify, lyrics: lyrics, mode: .lockScreen)
            }
        }
    }

    private func beginLockScreenActivity() {
        guard lockScreenActivity == nil else { return }
        lockScreenActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Showing Spotify playback while the Mac is locked"
        )
    }

    private func endLockScreenActivity() {
        guard let lockScreenActivity else { return }
        ProcessInfo.processInfo.endActivity(lockScreenActivity)
        self.lockScreenActivity = nil
    }
}
