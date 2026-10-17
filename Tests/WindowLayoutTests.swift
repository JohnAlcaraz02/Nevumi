import AppKit
import Carbon.HIToolbox

// swiftc -module-cache-path /tmp/nevumi-swift-module-cache
// Nevumi/Services/WindowManagementController.swift Nevumi/Views/WindowShortcutsSettingsView.swift
// Tests/WindowLayoutTests.swift -o /tmp/nevumi-window-tests
@main
struct WindowLayoutTests {
    static func main() throws {
        let desktop = CGRect(x: 0, y: 38, width: 1513, height: 900)
        let left = WindowLayout.target(.left, visibleFrame: desktop)
        let right = WindowLayout.target(.right, visibleFrame: desktop)
        precondition(left == CGRect(x: 0, y: 38, width: 756, height: 900))
        precondition(right == CGRect(x: 756, y: 38, width: 757, height: 900))
        precondition(left.maxX == right.minX && right.maxX == desktop.maxX)
        precondition(WindowLayout.target(.maximize, visibleFrame: desktop) == desktop)

        let primaryHeight: CGFloat = 982
        let primaryVisible = CGRect(x: 0, y: 60, width: 1512, height: 884)
        precondition(WindowLayout.accessibilityRect(primaryVisible, primaryHeight: primaryHeight)
                     == CGRect(x: 0, y: 38, width: 1512, height: 884))
        // External display to the left and above the primary screen.
        let external = CGRect(x: -1920, y: 500, width: 1920, height: 1080)
        let externalAX = WindowLayout.accessibilityRect(external, primaryHeight: primaryHeight)
        precondition(externalAX == CGRect(x: -1920, y: -598, width: 1920, height: 1080))
        let frames = [CGRect(x: 0, y: 0, width: 1512, height: 982), externalAX]
        precondition(WindowLayout.screenIndex(for: CGRect(x: -1200, y: -200, width: 800, height: 600), screens: frames) == 1)
        precondition(WindowLayout.screenIndex(for: CGRect(x: -100, y: 50, width: 900, height: 600), screens: frames) == 0)
        precondition(WindowLayout.screenIndex(for: desktop, screens: []) == nil)
        precondition(WindowLayout.screenIndex(for: CGRect(x: 4000, y: 50, width: 900, height: 600), screens: frames) == 0)

        let original = CGRect(x: 130, y: 100, width: 900, height: 600)
        precondition(WindowLayout.fit(original, in: desktop) == original)
        let offscreen = CGRect(x: -2000, y: -500, width: 2200, height: 1500)
        precondition(WindowLayout.fit(offscreen, in: desktop) == desktop)
        precondition(WindowLayout.fit(CGRect(x: 1400, y: 850, width: 800, height: 600), in: desktop)
                     == CGRect(x: 713, y: 338, width: 800, height: 600))

        let shortcuts = WindowAction.allCases.map(\.defaultShortcut)
        precondition(Set(shortcuts.map(\.keyCode)).count == 5)
        precondition(shortcuts.allSatisfy { $0.modifiers == UInt32(controlKey | optionKey) })
        precondition(WindowAction.left.defaultShortcut.label == "⌃⌥←")
        precondition(WindowAction.focusOther.defaultShortcut.keyCode == UInt32(kVK_Tab))
        precondition(WindowAction.focusOther.defaultShortcut.label == "⌃⌥⇥")
        let display = [desktop]
        precondition(WindowLayout.isOnSameDisplay(right, focused: left, screens: display))
        precondition(WindowLayout.isOnSameDisplay(left, focused: right, screens: display))
        // Regression: a large editor overlaps most of a smaller window.
        let editor = CGRect(x: 0, y: 38, width: 1180, height: 900)
        let documentation = CGRect(x: 760, y: 38, width: 753, height: 700)
        precondition(WindowLayout.isOnSameDisplay(documentation, focused: editor, screens: display))
        precondition(WindowLayout.isOnSameDisplay(editor, focused: documentation, screens: display))
        // Distinct windows with identical frames are eligible; AX identity excludes self.
        precondition(WindowLayout.isOnSameDisplay(editor, focused: editor, screens: display))
        precondition(WindowLayout.isOnSameDisplay(CGRect(x: 200, y: 200, width: 200, height: 150), focused: editor, screens: display))
        precondition(!WindowLayout.isOnSameDisplay(externalAX, focused: editor, screens: frames))
        precondition(!WindowLayout.isOnSameDisplay(editor, focused: externalAX, screens: frames))
        precondition(!WindowLayout.isOnSameDisplay(.zero, focused: editor, screens: display))
        precondition(!WindowLayout.isOnSameDisplay(editor, focused: editor, screens: []))
        precondition(!WindowLayout.isOnSameDisplay(editor.offsetBy(dx: 5000, dy: 0), focused: editor, screens: display))
        let shortcut = WindowAction.right.defaultShortcut
        let decoded = try JSONDecoder().decode(WindowShortcut.self, from: JSONEncoder().encode(shortcut))
        precondition(decoded == shortcut)
        precondition(shortcut.matches(WindowShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, keyLabel: "Different label")))
        print("Window layout and shortcut tests passed.")
    }
}
