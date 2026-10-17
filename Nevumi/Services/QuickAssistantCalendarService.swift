import EventKit
import Foundation

struct QuickAssistantCalendarEntry {
    let title: String
    let notes: String
    let startDate: Date
    let durationMinutes: Int
    let isAllDay: Bool
}

@MainActor
final class QuickAssistantCalendarService {
    private let eventStore = EKEventStore()

    func add(_ entry: QuickAssistantCalendarEntry) async throws -> String {
        guard try await ensureWriteAccess() else {
            throw CalendarError.accessDenied
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarError.noDefaultCalendar
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = entry.title
        event.notes = entry.notes.isEmpty ? nil : entry.notes
        event.calendar = calendar
        event.isAllDay = entry.isAllDay

        if entry.isAllDay {
            let startOfDay = Calendar.current.startOfDay(for: entry.startDate)
            event.startDate = startOfDay
            event.endDate = Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: startOfDay
            ) ?? startOfDay.addingTimeInterval(86_400)
        } else {
            event.startDate = entry.startDate
            event.endDate = entry.startDate.addingTimeInterval(
                TimeInterval(max(15, entry.durationMinutes) * 60)
            )
        }

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
        return calendar.title
    }

    private func ensureWriteAccess() async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            return true
        case .notDetermined:
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestWriteOnlyAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        case .denied:
            throw CalendarError.accessDenied
        case .restricted:
            throw CalendarError.accessRestricted
        @unknown default:
            throw CalendarError.accessDenied
        }
    }

    enum CalendarError: LocalizedError {
        case accessDenied
        case accessRestricted
        case noDefaultCalendar
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Calendar access is off. Enable Nevumi in System Settings → Privacy & Security → Calendars."
            case .accessRestricted:
                return "Calendar access is restricted on this Mac."
            case .noDefaultCalendar:
                return "Calendar has no default event calendar. Choose one in Calendar settings and try again."
            case .saveFailed(let message):
                return "The calendar note could not be saved. " + message
            }
        }
    }
}
