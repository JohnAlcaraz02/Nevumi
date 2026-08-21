import SwiftUI

@main
struct SleepMusicApp: App {
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
