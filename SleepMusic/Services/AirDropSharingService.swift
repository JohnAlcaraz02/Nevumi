import AppKit

/// Presents the system AirDrop share window for files dropped on the notch's
/// AirDrop half. The `NSSharingService` must stay strongly referenced for as
/// long as its window is up, otherwise the share is cancelled mid-flight.
@MainActor
final class AirDropSharingService {
    static let shared = AirDropSharingService()

    private var activeService: NSSharingService?

    private init() {}

    func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            print("[AirDrop] sendViaAirDrop unavailable on this Mac")
            return
        }
        guard service.canPerform(withItems: urls) else {
            print("[AirDrop] cannot share \(urls.map(\.lastPathComponent))")
            return
        }

        // The share window needs the app frontmost to appear above other
        // apps; SleepMusic normally runs as a background agent.
        NSApp.activate(ignoringOtherApps: true)
        activeService = service
        service.perform(withItems: urls)
        print("[AirDrop] share window presented for \(urls.count) item(s)")
    }
}
