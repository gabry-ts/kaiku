import Foundation

/// What to do when a source starts using the microphone.
public enum SourceRule: String, Codable, Sendable {
    /// Record (or offer to record) as usual.
    case always
    /// Ignore, as if the app never used the mic.
    case never
    /// Not decided yet: record first, then ask.
    case new
}

/// Where a call comes from, e.g. "WhatsApp" for both the WhatsApp app and WhatsApp Web.
public struct CallSource: Equatable, Sendable {
    public let name: String
    /// Bundle identifier prefixes of the native app.
    public let bundlePrefixes: [String]
    /// Words that identify the service in a browser window title.
    public let titleKeywords: [String]
    public let defaultRule: SourceRule

    /// Source of recordings started by hand.
    public static let manual = "Manual"

    public static let known: [CallSource] = [
        CallSource(name: "Zoom", bundlePrefixes: ["us.zoom."], titleKeywords: ["Zoom"], defaultRule: .always),
        CallSource(name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams"], titleKeywords: ["Microsoft Teams"], defaultRule: .always),
        CallSource(name: "Slack", bundlePrefixes: ["com.tinyspeck.slackmacgap"], titleKeywords: ["Slack"], defaultRule: .always),
        CallSource(name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"], titleKeywords: [], defaultRule: .always),
        CallSource(name: "Phone", bundlePrefixes: ["com.apple.mobilephone"], titleKeywords: [], defaultRule: .always),
        CallSource(name: "Webex", bundlePrefixes: ["com.webex.", "com.cisco.webex", "Cisco-Systems.Spark"], titleKeywords: ["Webex"], defaultRule: .always),
        CallSource(name: "Discord", bundlePrefixes: ["com.hnc.Discord"], titleKeywords: ["Discord"], defaultRule: .always),
        CallSource(name: "GoTo Meeting", bundlePrefixes: ["com.logmein.GoToMeeting"], titleKeywords: ["GoTo"], defaultRule: .always),
        CallSource(name: "RingCentral", bundlePrefixes: ["com.ringcentral.glip"], titleKeywords: ["RingCentral"], defaultRule: .always),
        CallSource(name: "Jitsi Meet", bundlePrefixes: [], titleKeywords: ["Jitsi Meet"], defaultRule: .always),
        CallSource(name: "Google Meet", bundlePrefixes: [], titleKeywords: ["Meet"], defaultRule: .always),
        CallSource(name: "Whereby", bundlePrefixes: [], titleKeywords: ["Whereby"], defaultRule: .always),
        CallSource(name: "WhatsApp", bundlePrefixes: ["net.whatsapp.WhatsApp"], titleKeywords: ["WhatsApp"], defaultRule: .new),
        CallSource(name: "Telegram", bundlePrefixes: ["ru.keepcoder.Telegram", "org.telegram.desktop"], titleKeywords: ["Telegram"], defaultRule: .new),
        CallSource(name: "Signal", bundlePrefixes: ["org.whispersystems.signal-desktop"], titleKeywords: [], defaultRule: .new),
        CallSource(name: "Viber", bundlePrefixes: ["com.viber.osx"], titleKeywords: [], defaultRule: .new),
        CallSource(name: "Element", bundlePrefixes: ["im.riot.app"], titleKeywords: ["Element"], defaultRule: .new),
    ]

    /// The known source of a native app.
    public static func native(bundleID: String) -> CallSource? {
        known.first { s in s.bundlePrefixes.contains { bundleID.hasPrefix($0) } }
    }

    /// Source name for a process using the mic: the native app's source, or for a browser
    /// the normalized front window title, falling back to the browser name.
    /// nil for apps that are neither.
    public static func resolve(bundleID: String, windowTitle: String?) -> String? {
        if let source = native(bundleID: bundleID) { return source.name }
        guard let browser = MeetingApp.match(bundleID: bundleID), browser.isBrowser else { return nil }
        return windowTitle.flatMap(normalizeBrowserTitle) ?? browser.name
    }

    /// "(3) WhatsApp" → "WhatsApp", "Meet – abc-defg-hij – Google Chrome" → "Google Meet",
    /// "Chat | Microsoft Teams" → "Microsoft Teams". Unknown titles keep their first part.
    /// nil when nothing is left.
    public static func normalizeBrowserTitle(_ title: String) -> String? {
        let parts = titleParts(title)
        for part in parts {
            if let source = known.first(where: { $0.titleKeywords.contains { containsWords(part, $0) } }) {
                return source.name
            }
        }
        return parts.first
    }

    /// Title split on " – " / " - " / " — " / " | ", without the unread counter and
    /// the browser name. Empty parts are dropped.
    public static func titleParts(_ title: String) -> [String] {
        var t = title.replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let counter = t.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) {
            t.removeSubrange(counter)
        }
        return t.components(separatedBy: " | ")
            .flatMap { $0.components(separatedBy: " – ") }
            .flatMap { $0.components(separatedBy: " — ") }
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: separatorEdges) }
            .filter { !$0.isEmpty && !isBrowserName($0) }
    }

    private static let separatorEdges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—|"))

    private static let browserNames: Set<String> = Set(
        (MeetingApp.known.filter(\.isBrowser).map(\.name) + ["Mozilla Firefox"]).map { $0.lowercased() })

    private static func isBrowserName(_ s: String) -> Bool { browserNames.contains(s.lowercased()) }

    /// Whether `text` contains the words of `keyword` in a row, so "Meet" matches
    /// "Google Meet" but not "Meeting notes".
    private static func containsWords(_ text: String, _ keyword: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        let key = keyword.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !key.isEmpty, words.count >= key.count else { return false }
        return (0...(words.count - key.count)).contains { Array(words[$0..<($0 + key.count)]) == key }
    }
}

/// A call noticed by call detection: its source and the app it runs in.
public struct DetectedCall: Equatable, Sendable {
    public let source: String
    /// e.g. "Google Chrome" for WhatsApp Web.
    public let app: String

    public init(source: String, app: String) {
        self.source = source
        self.app = app
    }
}

/// Always/Never choices saved per source name (case-insensitive).
public struct SourceRules: Codable, Equatable, Sendable {
    public private(set) var saved: [String: SourceRule]

    public init(_ saved: [String: SourceRule] = [:]) { self.saved = saved }

    /// Saved choice, else the known source's default, else `.new`.
    public func rule(for source: String) -> SourceRule {
        if let key = saved.keys.first(where: { $0.caseInsensitiveCompare(source) == .orderedSame }) {
            return saved[key]!
        }
        return CallSource.known.first { $0.name.caseInsensitiveCompare(source) == .orderedSame }?.defaultRule ?? .new
    }

    public mutating func set(_ rule: SourceRule, for source: String) {
        for key in saved.keys where key.caseInsensitiveCompare(source) == .orderedSame { saved[key] = nil }
        saved[source] = rule
    }

    /// Sources to list in Settings: the known ones first, then every other source seen
    /// or decided, alphabetically, without duplicates (case-insensitive).
    public func listed(seen: [String]) -> [String] {
        let others = (seen + saved.keys).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var out: [String] = []
        for name in CallSource.known.map(\.name) + others
        where !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            out.append(name)
        }
        return out
    }

    /// Rules from the old per-app toggles: disabled apps become `.never`. Browsers are
    /// dropped, since a browser is no longer a source on its own.
    public static func migrated(disabledAppIDs: [String]) -> SourceRules {
        var rules = SourceRules()
        for id in disabledAppIDs {
            guard let app = MeetingApp.known.first(where: { $0.id == id }), !app.isBrowser else { continue }
            rules.set(.never, for: app.name)
        }
        return rules
    }
}

/// Source of each app using the mic, resolved once when the app starts using it and
/// kept until it stops, so switching browser tabs mid-call doesn't change the source.
public struct SourceCache: Sendable {
    /// App key → source name.
    public private(set) var sources: [String: String] = [:]

    public init() {}

    /// Forgets apps that stopped using the mic and resolves the ones that just started.
    public mutating func update(active: Set<String>, resolve: (String) -> String) -> [String: String] {
        sources = sources.filter { active.contains($0.key) }
        for key in active where sources[key] == nil { sources[key] = resolve(key) }
        return sources
    }
}
