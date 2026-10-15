import EventKit
import KaikuCore

/// Reads the calendar event happening now, to prefill the call title and store attendees,
/// and today's meetings with a join link for the meeting bot.
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
                attendees: (e.attendees ?? []).filter { !$0.isCurrentUser }.map { .init(name: $0.name, email: Self.email(of: $0)) },
                isAllDay: e.isAllDay,
                ownEmail: Self.ownEmail(in: e))
        }
        return CalendarEventInfo.best(events, now: now)
    }

    /// A meeting of today the bot can join.
    struct Meeting: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let link: MeetingLink
    }

    /// Today's meetings with a Meet or Teams link that haven't ended, from the chosen calendars.
    func todayMeetings(now: Date = Date()) -> [Meeting] {
        guard AppSettings.calendarEnabled, state == .granted else { return [] }
        let chosen = Set(AppSettings.calendarIDs)
        let calendars = store.calendars(for: .event).filter { chosen.isEmpty || chosen.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty, let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))
        else { return [] }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600), end: endOfDay, calendars: calendars)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .compactMap { e in
                let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: "\n")
                guard let link = MeetingLink.find(in: text) else { return nil }
                return Meeting(id: (e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                               title: e.title ?? link.platform.name, start: e.startDate, end: e.endDate, link: link)
            }
            .sorted { $0.start < $1.start }
    }

    private static func email(of participant: EKParticipant) -> String? {
        let url = participant.url.absoluteString
        return url.lowercased().hasPrefix("mailto:") ? String(url.dropFirst(7)) : nil
    }

    /// Your address in the event, else the account's when it is named after it (Google, iCloud).
    private static func ownEmail(in event: EKEvent) -> String? {
        if let me = event.attendees?.first(where: \.isCurrentUser), let email = email(of: me) { return email }
        guard let account = event.calendar?.source.title, account.contains("@") else { return nil }
        return account
    }
}
