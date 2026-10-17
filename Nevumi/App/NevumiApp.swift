import SwiftUI

@MainActor
private final class NevumiApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit windows must be created only after application launch has
        // completed. Starting the notch receiver earlier causes NSWindow to
        // abort while SwiftUI is still constructing its scenes.
        NotchFileDropController.shared.start()
    }
}

@main
struct NevumiApp: App {
    @NSApplicationDelegateAdaptor(NevumiApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var loginItem = LoginItemManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(coordinator: coordinator, loginItem: loginItem)
        } label: {
            Image("NevumiMark")
                .renderingMode(.template)
                .accessibilityLabel("Nevumi")
        }
        .menuBarExtraStyle(.menu)
    }
}

