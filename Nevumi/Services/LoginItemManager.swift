import Foundation
import ServiceManagement

/// Registers Nevumi as a macOS login item via `SMAppService`, so once
/// it's been opened (or installed) once, it launches automatically on every
/// subsequent login — the user never has to open it manually again.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private static let hasAutoEnabledKey = "LoginItemManager.hasAutoEnabled"

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
        autoEnableOnFirstLaunch()
    }

    func enable() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Leaves isEnabled reflecting whatever the real status is,
            // e.g. registration can fail before the app is code-signed
            // and running from a stable location.
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func disable() {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            // no-op, see enable()
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// The very first time this app runs, register it as a login item so
    /// installing it is enough — the user doesn't need to dig into System
    /// Settings. If they later turn it off from the menu, that choice is
    /// respected on every future launch.
    private func autoEnableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.hasAutoEnabledKey) else { return }
        defaults.set(true, forKey: Self.hasAutoEnabledKey)
        enable()
    }
}
