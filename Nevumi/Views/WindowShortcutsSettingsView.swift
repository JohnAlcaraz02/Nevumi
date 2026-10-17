import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

struct WindowShortcutsSettingsView: View {
    @ObservedObject var controller: WindowManagementController
    @State private var hasAccessibility = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            Text("Control windows and capture long screenshots from any app.")
                .foregroundStyle(.secondary)
            Toggle("Enable these shortcuts", isOn: $controller.isEnabled)
            Divider()
            ForEach(WindowAction.allCases) { action in
                HStack {
                    Text(action.title)
                    Spacer()
                    if let shortcut = controller.shortcuts[action] {
                        WindowShortcutRecorder(shortcut: shortcut, onRecordingChanged: controller.setRecordingShortcut) {
                            controller.setShortcut($0, for: action)
                        }
                        .frame(width: 170, height: 28)
                        .disabled(!controller.isEnabled)
                    }
                }
            }
            Text("Click a shortcut, then press a new combination with Control, Option, or Command. Press Esc to cancel.")
                .font(.caption).foregroundStyle(.secondary)
            Text("The focus shortcut switches to another window on the same display, at any size or overlap.")
                .font(.caption).foregroundStyle(.secondary)
            if !controller.status.isEmpty {
                Text(controller.status).font(.callout).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "hand.raised.fill")
                    .foregroundStyle(hasAccessibility ? Color.green : Color.secondary)
                Text(hasAccessibility ? "Accessibility access enabled" : "Accessibility access required")
                Spacer()
                Button(hasAccessibility ? "Open Settings…" : "Allow Access…") {
                    controller.requestAccessibility()
                }
            }
            Text("Full-screen windows must leave full screen first. Some apps limit how small their windows can be.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Long screenshots use Screen Recording access. Accessibility is needed only for window control.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Restore Default Shortcuts") { controller.resetShortcuts() }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = AXIsProcessTrusted()
        }
    }
}

private struct WindowShortcutRecorder: NSViewRepresentable {
    var shortcut: WindowShortcut
    var onRecordingChanged: (Bool) -> Void
    var onRecord: (WindowShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecordButton {
        let button = ShortcutRecordButton()
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        button.setAccessibilityLabel("Record keyboard shortcut")
        return button
    }

    func updateNSView(_ button: ShortcutRecordButton, context: Context) {
        button.shortcut = shortcut
        button.onRecord = onRecord
        button.onRecordingChanged = onRecordingChanged
        button.isEnabled = context.environment.isEnabled
        if !button.isRecording { button.title = shortcut.label }
    }
}

private final class ShortcutRecordButton: NSButton {
    var shortcut: WindowShortcut?
    var onRecord: ((WindowShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var isRecording = false {
        didSet { if isRecording != oldValue { onRecordingChanged?(isRecording) } }
    }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isRecording = true
        title = "Press shortcut…"
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        title = shortcut?.label ?? "Record shortcut"
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !isRecording {
            if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                isRecording = true
                title = "Press shortcut…"
            } else { super.keyDown(with: event) }
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            title = shortcut?.label ?? "Record shortcut"
            return
        }
        let flags = event.modifierFlags
        guard !flags.intersection([.control, .option, .command]).isEmpty else {
            NSSound.beep()
            return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let specialKeys: [UInt16: String] = [
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩",
            UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
        ]
        let label = specialKeys[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty else { NSSound.beep(); return }
        isRecording = false
        onRecord?(WindowShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label))
        title = shortcut?.label ?? "Record shortcut"
    }
}
