import SwiftUI

@MainActor
private final class SleepMusicApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit windows must be created only after application launch has
        // completed. Starting the notch receiver earlier causes NSWindow to
        // abort while SwiftUI is still constructing its scenes.
        NotchFileDropController.shared.start()
    }
}

@main
struct SleepMusicApp: App {
    @NSApplicationDelegateAdaptor(SleepMusicApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var loginItem = LoginItemManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(coordinator: coordinator, loginItem: loginItem)
        } label: {
            Image(systemName: "moon.stars.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

