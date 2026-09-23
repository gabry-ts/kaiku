import Foundation

/// An app that usually means "I'm in a call" when it uses the microphone.
public struct MeetingApp: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Bundle identifier prefixes, which also match helper processes.
    public let bundlePrefixes: [String]
    public let isBrowser: Bool

    public static let known: [MeetingApp] = [
        MeetingApp(id: "zoom", name: "Zoom", bundlePrefixes: ["us.zoom."], isBrowser: false),
        MeetingApp(id: "teams", name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams"], isBrowser: false),
        MeetingApp(id: "slack", name: "Slack", bundlePrefixes: ["com.tinyspeck.slackmacgap"], isBrowser: false),
        MeetingApp(id: "facetime", name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"], isBrowser: false),
        MeetingApp(id: "webex", name: "Webex", bundlePrefixes: ["com.webex.", "com.cisco.webex", "Cisco-Systems.Spark"], isBrowser: false),
        MeetingApp(id: "discord", name: "Discord", bundlePrefixes: ["com.hnc.Discord"], isBrowser: false),
        MeetingApp(id: "chrome", name: "Google Chrome", bundlePrefixes: ["com.google.Chrome"], isBrowser: true),
        MeetingApp(id: "safari", name: "Safari", bundlePrefixes: ["com.apple.Safari", "com.apple.WebKit.GPU"], isBrowser: true),
        MeetingApp(id: "arc", name: "Arc", bundlePrefixes: ["company.thebrowser."], isBrowser: true),
        MeetingApp(id: "edge", name: "Microsoft Edge", bundlePrefixes: ["com.microsoft.edgemac"], isBrowser: true),
        MeetingApp(id: "firefox", name: "Firefox", bundlePrefixes: ["org.mozilla."], isBrowser: true),
        MeetingApp(id: "brave", name: "Brave", bundlePrefixes: ["com.brave.Browser"], isBrowser: true),
        MeetingApp(id: "zen", name: "Zen", bundlePrefixes: ["app.zen-browser."], isBrowser: true),
        MeetingApp(id: "vivaldi", name: "Vivaldi", bundlePrefixes: ["com.vivaldi.Vivaldi"], isBrowser: true),
    ]

    public static func match(bundleID: String) -> MeetingApp? {
        known.first { app in app.bundlePrefixes.contains { bundleID.hasPrefix($0) } }
    }
}

/// Turns the set of meeting apps using the microphone, sampled over time, into
/// "call started" / "call ended" / "auto-stop" events. No timers or audio inside.
public struct MeetingDetector: Sendable {
    public enum Event: Equatable, Sendable {
        /// A meeting app started using the mic while we are not recording.
        case started(appID: String)
        /// Every meeting app seen during this recording stopped using the mic.
        case ended(appID: String)
        /// Still ended after the auto-stop delay.
        case autoStop
    }

    /// 0 disables auto-stop.
    public var autoStopAfter: Double
    private var active: Set<String> = []
    private var seenWhileRecording: String?
    private var endedAt: Date?

    public init(autoStopAfter: Double = 0) { self.autoStopAfter = autoStopAfter }

    public mutating func update(active newActive: Set<String>, isRecording: Bool, now: Date) -> [Event] {
        var events: [Event] = []
        let appeared = newActive.subtracting(active)
        if !isRecording {
            seenWhileRecording = nil
            endedAt = nil
            if let app = appeared.sorted().first { events.append(.started(appID: app)) }
        } else {
            if let app = newActive.sorted().first {
                seenWhileRecording = app
                endedAt = nil
            } else if let app = seenWhileRecording {
                if endedAt == nil {
                    endedAt = now
                    events.append(.ended(appID: app))
                } else if let t = endedAt, autoStopAfter > 0, now.timeIntervalSince(t) >= autoStopAfter {
                    events.append(.autoStop)
                    seenWhileRecording = nil
                    endedAt = nil
                }
            }
        }
        active = newActive
        return events
    }
}

/// A calendar event, as stored in meta.json.
public struct CalendarEventInfo: Codable, Equatable, Sendable {
    public struct Attendee: Codable, Equatable, Sendable {
        public var name: String?
        public var email: String?
        public init(name: String?, email: String?) {
            self.name = name
            self.email = email
        }
    }

    public var title: String
    public var calendar: String?
    public var start: Date
    public var end: Date
    public var attendees: [Attendee]
    public var isAllDay: Bool?

    public init(title: String, calendar: String?, start: Date, end: Date, attendees: [Attendee], isAllDay: Bool? = nil) {
        self.title = title
        self.calendar = calendar
        self.start = start
        self.end = end
        self.attendees = attendees
        self.isAllDay = isAllDay
    }

    /// Picks the event that best matches a call starting `now`: in progress, or starting
    /// within `window` seconds. All-day events are ignored. Closest start wins.
    public static func best(_ events: [CalendarEventInfo], now: Date, window: Double = 600) -> CalendarEventInfo? {
        events
            .filter { $0.isAllDay != true && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { e in
                (e.start <= now && now < e.end) || abs(e.start.timeIntervalSince(now)) <= window
            }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    /// Attendee names (or email local parts) for speaker suggestions.
    public var attendeeNames: [String] {
        var out: [String] = []
        for a in attendees {
            let name = a.name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? a.email.flatMap { $0.split(separator: "@").first.map(String.init) }
            if let name, !out.contains(name) { out.append(name) }
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
