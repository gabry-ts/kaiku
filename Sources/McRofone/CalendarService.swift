import EventKit
import McRofoneCore

/// Reads the calendar event happening now, to prefill the call title and store attendees.
@MainActor
final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    var state: PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        store.reset()
        return granted
    }

    /// Event calendars, grouped by account title in the order macOS returns them.
    func calendars() -> [EKCalendar] {
        guard state == .granted else { return [] }
        return store.calendars(for: .event).sorted {
            ($0.source.title, $0.title) < ($1.source.title, $1.title)
        }
    }

    /// The event in progress or starting within 10 minutes, from the chosen calendars.
    func currentEvent(now: Date = Date()) -> CalendarEventInfo? {
        guard AppSettings.calendarEnabled, state == .granted else { return nil }
        let chosen = Set(AppSettings.calendarIDs)
        let calendars = store.calendars(for: .event).filter { chosen.isEmpty || chosen.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(15 * 60), calendars: calendars)
        let events = store.events(matching: predicate).map { e in
            CalendarEventInfo(
                title: e.title ?? "",
                calendar: e.calendar?.title,
                start: e.startDate,
                end: e.endDate,
                attendees: (e.attendees ?? []).filter { !$0.isCurrentUser }.map { p in
                    let email = p.url.absoluteString.lowercased().hasPrefix("mailto:")
                        ? String(p.url.absoluteString.dropFirst(7)) : nil
                    return .init(name: p.name, email: email)
                },
                isAllDay: e.isAllDay)
        }
        return CalendarEventInfo.best(events, now: now)
    }
}
