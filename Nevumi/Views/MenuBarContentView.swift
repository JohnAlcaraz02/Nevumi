import SwiftUI

/// The entire user-facing surface of Nevumi: a menu bar dropdown, since
/// the app itself has no Dock icon or window to open.
struct MenuBarContentView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var loginItem: LoginItemManager

    var body: some View {
        if let nowPlaying = coordinator.spotify.nowPlaying {
            Text("\(nowPlaying.title) — \(nowPlaying.artist)")
        } else {
            Text("Not Playing")
        }

        Button("Enter Sleep Mode") {
            SleepOverlayController.shared.show(spotify: coordinator.spotify, lyrics: coordinator.lyrics)
        }
        .disabled(coordinator.spotify.nowPlaying == nil)

        Button("Open Quick Assistant") {
            QuickAssistantWindowController.shared.show()
        }
        .keyboardShortcut(.space, modifiers: .option)

        Button("Capture Long Screenshot…") {
            LongScreenshotController.shared.start()
        }

        Divider()

        Button("Keyboard Shortcuts…") {
            coordinator.windowManagement.showSettings()
        }

        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { loginItem.isEnabled },
                set: { isOn in isOn ? loginItem.enable() : loginItem.disable() }
            )
        )

        Divider()

        Button("Quit Nevumi") {
            NSApplication.shared.terminate(nil)
        }
    }
}
