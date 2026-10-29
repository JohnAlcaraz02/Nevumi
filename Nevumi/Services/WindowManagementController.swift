import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

enum WindowAction: UInt32, CaseIterable, Identifiable {
    case left = 1, right, maximize, restore
    case focusOther = 6
    case longScreenshot = 7
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .left: return "Left half"
        case .right: return "Right half"
        case .maximize: return "Maximize"
        case .restore: return "Restore previous size"
        case .focusOther: return "Focus other window"
        case .longScreenshot: return "Capture long screenshot"
        }
    }
    var defaultShortcut: WindowShortcut {
        let key: Int
        switch self {
        case .left: key = kVK_LeftArrow
        case .right: key = kVK_RightArrow
        case .maximize: key = kVK_UpArrow
        case .restore: key = kVK_DownArrow
        case .focusOther: key = kVK_Tab
        case .longScreenshot: key = kVK_ANSI_S
        }
        return WindowShortcut(keyCode: UInt32(key), modifiers: UInt32(controlKey | optionKey),
                              keyLabel: [.left: "←", .right: "→", .maximize: "↑", .restore: "↓", .focusOther: "⇥", .longScreenshot: "S"][self]!)
    }
}

struct WindowShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + keyLabel
    }
    func matches(_ other: Self) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// Geometry is in Accessibility coordinates: origin at the primary display's top left.
enum WindowLayout {
    static func isOnSameDisplay(_ candidate: CGRect, focused: CGRect, screens: [CGRect]) -> Bool {
        guard candidate.width > 0, candidate.height > 0, focused.width > 0, focused.height > 0 else { return false }
        guard let display = screenIndex(for: focused, screens: screens) else { return false }
        // Window identity is checked separately, so equally sized and fully
        // overlapping windows remain eligible for focus switching.
        return candidate.intersects(screens[display]) &&
            screenIndex(for: candidate, screens: screens) == display
    }

    static func accessibilityRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func target(_ action: WindowAction, visibleFrame: CGRect) -> CGRect {
        var result = visibleFrame
        if action == .left || action == .right {
            let leftWidth = floor(visibleFrame.width / 2)
            result.size.width = action == .left ? leftWidth : visibleFrame.width - leftWidth
            if action == .right { result.origin.x += leftWidth }
        }
        return result
    }

    static func fit(_ rect: CGRect, in visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(rect.width, visibleFrame.width), height: min(rect.height, visibleFrame.height))
        return CGRect(x: max(visibleFrame.minX, min(rect.minX, visibleFrame.maxX - size.width)),
                      y: max(visibleFrame.minY, min(rect.minY, visibleFrame.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    static func screenIndex(for window: CGRect, screens: [CGRect]) -> Int? {
        guard let largest = screens.indices.max(by: { a, b in
            let first = screens[a].intersection(window)
            let second = screens[b].intersection(window)
            return (first.isNull ? 0 : first.width * first.height) <
                (second.isNull ? 0 : second.width * second.height)
        }) else { return nil }
        if screens[largest].intersects(window) { return largest }
        // A display may have been unplugged since the original frame was saved.
        func distance(to rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - window.midX, 0, window.midX - rect.maxX)
            let dy = max(rect.minY - window.midY, 0, window.midY - rect.maxY)
            return dx * dx + dy * dy
        }
        return screens.indices.min { distance(to: screens[$0]) < distance(to: screens[$1]) }
    }
}

/// AX and WindowServer can disagree about a window's title bar and tiled edges.
/// Rank plausible matches instead of requiring every dimension to match exactly.
enum WindowFocusMatching {
    static func score(accessibilityFrame actual: CGRect, serverFrame visible: CGRect) -> CGFloat? {
        guard actual.width > 0, actual.height > 0, visible.width > 0, visible.height > 0 else { return nil }
        let overlap = actual.intersection(visible)
        guard !overlap.isNull else { return nil }
        let coverage = overlap.width * overlap.height / max(actual.width * actual.height, visible.width * visible.height)
        let delta = abs(actual.minX - visible.minX) + abs(actual.minY - visible.minY)
            + abs(actual.maxX - visible.maxX) + abs(actual.maxY - visible.maxY)
        guard coverage >= 0.8, delta <= 160 else { return nil }
        return coverage - delta / 1000
    }

    static func isRegularWindow(role: String?, subrole: String?) -> Bool {
        (role == nil || role == kAXWindowRole) && (subrole == nil || subrole == kAXStandardWindowSubrole)
    }
}

@MainActor
final class WindowManagementController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "windowShortcutsEnabled")
            registerShortcuts()
        }
    }
    @Published private(set) var shortcuts: [WindowAction: WindowShortcut] = [:]
    @Published private(set) var status = ""
    private let defaults: UserDefaults
    private let captureLongScreenshot: () -> Void
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var settingsWindow: NSWindow?
    private var isRecordingShortcut = false
    private struct SavedWindow {
        let window: AXUIElement
        let pid: pid_t
        let frame: CGRect
    }
    private var savedWindows: [SavedWindow] = []
    private var focusTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, captureLongScreenshot: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.captureLongScreenshot = captureLongScreenshot
        isEnabled = defaults.object(forKey: "windowShortcutsEnabled") as? Bool ?? true
        super.init()
        for action in WindowAction.allCases {
            let saved = defaults.data(forKey: "windowShortcut.\(action.rawValue)")
                .flatMap { try? JSONDecoder().decode(WindowShortcut.self, from: $0) }
            shortcuts[action] = saved ?? action.defaultShortcut
        }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), windowShortcutHandler, 1, &type,
                                        Unmanaged.passUnretained(self).toOpaque(), &handler)
        if result == noErr { registerShortcuts() }
        else { status = "Keyboard shortcuts couldn’t start. Restart Nevumi to try again." }
    }

    deinit {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func registerShortcuts() {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        status = ""
        guard isEnabled, !isRecordingShortcut else { return }
        var conflicts: [String] = []
        for action in WindowAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                EventHotKeyID(signature: 0x4E56574D, id: action.rawValue), // NVWM
                GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { hotKeys.append(reference) }
            else { conflicts.append(action.title) }
        }
        if !conflicts.isEmpty {
            status = "Shortcut unavailable: \(conflicts.joined(separator: ", ")). Choose another key combination."
        }
    }

    func setShortcut(_ shortcut: WindowShortcut, for action: WindowAction) {
        guard !shortcuts.contains(where: { $0.key != action && $0.value.matches(shortcut) }),
              !(shortcut.keyCode == UInt32(kVK_Space) && shortcut.modifiers == UInt32(optionKey)) else {
            status = "That shortcut is already used by Nevumi. Choose another combination."
            return
        }
        let previous = shortcuts[action]
        shortcuts[action] = shortcut
        registerShortcuts()
        if !status.isEmpty {
            let failure = status
            shortcuts[action] = previous
            registerShortcuts()
            status = failure
            return
        }
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: "windowShortcut.\(action.rawValue)")
    }

    func setRecordingShortcut(_ recording: Bool) {
        isRecordingShortcut = recording
        registerShortcuts()
    }

    func resetShortcuts() {
        for action in WindowAction.allCases {
            shortcuts[action] = action.defaultShortcut
            defaults.removeObject(forKey: "windowShortcut.\(action.rawValue)")
        }
        registerShortcuts()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: WindowShortcutsSettingsView(controller: self))
            let window = NSWindow(contentViewController: controller)
            window.title = "Keyboard Shortcuts"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        stopRecording(in: notification)
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(in: notification)
    }

    private func stopRecording(in notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        window.makeFirstResponder(nil)
        if isRecordingShortcut { setRecordingShortcut(false) }
    }

    func perform(_ action: WindowAction) {
        guard isEnabled, !isRecordingShortcut else { return }
        if action == .longScreenshot {
            captureLongScreenshot()
            return
        }
        guard AXIsProcessTrusted() else {
            showMessage("Allow window control", "Enable Nevumi in System Settings → Privacy & Security → Accessibility, then try the shortcut again.", permission: true)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { NSSound.beep(); return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let value = attribute(kAXFocusedWindowAttribute, of: application),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { NSSound.beep(); return }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)
        if (attribute("AXFullScreen", of: window) as? Bool) == true {
            showMessage("Leave full screen first", "Window shortcuts work with desktop windows. Exit full screen and try again.")
            return
        }
        if action == .focusOther {
            focusTask?.cancel()
            focusTask = Task { @MainActor in await focusOtherWindow(beside: window) }
            return
        }
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable) == .success,
              AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success,
              positionSettable.boolValue, sizeSettable.boolValue,
              let current = frame(of: window) else {
            showMessage("This window can’t be resized", "Try a regular app window that supports moving and resizing.")
            return
        }
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let screenFrames = screens.map { WindowLayout.accessibilityRect($0.frame, primaryHeight: primary.frame.maxY) }
        guard let index = WindowLayout.screenIndex(for: current, screens: screenFrames) else { return }
        let visible = WindowLayout.accessibilityRect(screens[index].visibleFrame, primaryHeight: primary.frame.maxY)
        // Discard windows belonging to terminated processes and cap retained AX objects.
        savedWindows.removeAll { NSRunningApplication(processIdentifier: $0.pid) == nil }
        let savedIndex = savedWindows.firstIndex { $0.pid == app.processIdentifier && CFEqual($0.window, window) }
        let target: CGRect
        let targetBounds: CGRect
        if action == .restore {
            guard let savedIndex else { NSSound.beep(); return }
            let saved = savedWindows[savedIndex].frame
            let restoreScreen = WindowLayout.screenIndex(for: saved, screens: screenFrames) ?? index
            let restoreVisible = WindowLayout.accessibilityRect(screens[restoreScreen].visibleFrame, primaryHeight: primary.frame.maxY)
            target = WindowLayout.fit(saved, in: restoreVisible)
            targetBounds = restoreVisible
        } else {
            if savedIndex == nil {
                if savedWindows.count >= 100 { savedWindows.removeFirst() }
                savedWindows.append(SavedWindow(window: window, pid: app.processIdentifier, frame: current))
            }
            target = WindowLayout.target(action, visibleFrame: visible)
            targetBounds = visible
        }
        guard setFrame(target, of: window) else {
            _ = setFrame(current, of: window)
            if action != .restore, savedIndex == nil {
                savedWindows.removeAll { $0.pid == app.processIdentifier && CFEqual($0.window, window) }
            }
            showMessage("Couldn’t resize this window", "The app didn’t accept the requested position or size. Try another window.")
            return
        }
        // Respect an app's minimum size while keeping its window on the desktop.
        if let actual = frame(of: window) {
            let fitted = WindowLayout.fit(actual, in: targetBounds)
            var origin = fitted.origin
            if let value = AXValueCreate(.cgPoint, &origin) {
                _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
        }
        if action == .restore, let savedIndex { savedWindows.remove(at: savedIndex) }
    }

    private func focusOtherWindow(beside focused: AXUIElement) async {
        guard let current = frame(of: focused), let primary = NSScreen.screens.first,
              let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return }
        let screens = NSScreen.screens.map { WindowLayout.accessibilityRect($0.frame, primaryHeight: primary.frame.maxY) }
        let visibleWindows: [(pid: pid_t, frame: CGRect)] = entries.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 1, rect.height > 1,
                  WindowLayout.isOnSameDisplay(rect, focused: current, screens: screens) else { return nil }
            return (pid, rect)
        }
        var appWindows: [pid_t: [AXUIElement]] = [:]
        var attempted: [AXUIElement] = []
        var foundCandidate = false
        var couldNotReadWindows = false
        // Keep WindowServer's front-to-back order, including overlapping windows.
        for visible in visibleWindows {
            guard !Task.isCancelled else { return }
            if appWindows[visible.pid] == nil {
                let application = AXUIElementCreateApplication(visible.pid)
                AXUIElementSetMessagingTimeout(application, 0.5)
                var result: CFTypeRef?
                var status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &result)
                if status == .cannotComplete {
                    // Busy apps sometimes time out while updating tiled windows.
                    await Task.yield()
                    status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &result)
                }
                if status != .success { couldNotReadWindows = true }
                appWindows[visible.pid] = (result as? [AXUIElement] ?? []).filter { candidate in
                    AXUIElementSetMessagingTimeout(candidate, 0.5)
                    return WindowFocusMatching.isRegularWindow(
                        role: attribute(kAXRoleAttribute, of: candidate) as? String,
                        subrole: attribute(kAXSubroleAttribute, of: candidate) as? String
                    ) && (attribute(kAXMinimizedAttribute, of: candidate) as? Bool) != true
                      && (attribute("AXFullScreen", of: candidate) as? Bool) != true
                }
            }
            let windows = appWindows[visible.pid] ?? []
            var matches: [(window: AXUIElement, score: CGFloat)] = windows.compactMap { candidate in
                guard let actual = frame(of: candidate),
                      WindowLayout.isOnSameDisplay(actual, focused: current, screens: screens),
                      let score = WindowFocusMatching.score(accessibilityFrame: actual, serverFrame: visible.frame) else { return nil }
                return (candidate, score)
            }
            // A single AX window and a single visible window for this app are
            // unambiguous even when the app reports unusual frame decorations.
            if matches.isEmpty, windows.count == 1,
               visibleWindows.filter({ $0.pid == visible.pid }).count == 1,
               let candidate = windows.first, let actual = frame(of: candidate),
               WindowLayout.isOnSameDisplay(actual, focused: current, screens: screens) {
                matches = [(candidate, 0)]
            }
            for match in matches.sorted(by: { $0.score > $1.score }) {
                let candidate = match.window
                guard !CFEqual(candidate, focused), !attempted.contains(where: { CFEqual($0, candidate) }),
                      let app = NSRunningApplication(processIdentifier: visible.pid) else { continue }
                attempted.append(candidate)
                foundCandidate = true
                let application = AXUIElementCreateApplication(visible.pid)
                AXUIElementSetMessagingTimeout(application, 0.5)
                // Activation and raising are separate operations. Some apps
                // don't implement AXRaise but do accept focus on the app.
                _ = app.activate(options: [])
                _ = AXUIElementPerformAction(candidate, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(candidate, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, candidate)
                _ = AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == visible.pid,
                   let value = attribute(kAXFocusedWindowAttribute, of: application),
                   CFGetTypeID(value) == AXUIElementGetTypeID(), CFEqual(value, candidate) { return }
            }
        }
        if foundCandidate {
            showMessage("Couldn’t focus the other window", "The window is visible, but its app didn’t accept the focus request. Click it once, then try the shortcut again.")
        } else if couldNotReadWindows {
            showMessage("Couldn’t read the other windows", "An app didn’t respond to window access. Try the shortcut again, or check Nevumi’s Accessibility access in System Settings.")
        } else {
            showMessage("No other window found", "Open another app window on this display, then press the shortcut again. It can be any size or overlap this window.")
        }
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute, of: window),
              let size = attribute(kAXSizeAttribute, of: window),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func setFrame(_ rect: CGRect, of window: AXUIElement) -> Bool {
        var point = rect.origin
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        // Shrink first so a large window can move onto a smaller display.
        let firstSize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        let move = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        let finalSize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        return firstSize == .success && move == .success && finalSize == .success
    }

    private func showMessage(_ title: String, _ message: String, permission: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: permission ? "Open Accessibility Settings" : "OK")
        if permission { alert.addButton(withTitle: "Cancel") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, permission { requestAccessibility() }
    }
}

private let windowShortcutHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard result == noErr, identifier.signature == 0x4E56574D,
          let action = WindowAction(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<WindowManagementController>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in controller.perform(action) }
    return noErr
}
