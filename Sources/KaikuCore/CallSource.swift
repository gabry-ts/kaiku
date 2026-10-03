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

/// When a detected call starts recording by itself.
public enum AutoRecordMode: String, CaseIterable, Identifiable, Sendable {
    /// Never: a notification offers to record.
    case off
    /// Every source that isn't ignored; a source never seen before is recorded, then asked about.
    case all
    /// Only the sources chosen in Settings > Call Detection > Sources; the others are offered.
    case selected
    public var id: String { rawValue }

    /// Whether a call from a source with `rule` starts recording by itself.
    public func records(rule: SourceRule, chosen: Bool) -> Bool {
        switch self {
        case .off: return false
        case .all: return rule != .never
        case .selected: return rule == .always && chosen
        }
    }
}

/// Where a call comes from, e.g. "WhatsApp" for both the WhatsApp app and WhatsApp Web.
public struct CallSource: Equatable, Sendable {
    public let name: String
    /// Bundle identifier prefixes of the native app.
    public let bundlePrefixes: [String]
    /// Words that identify the service in a browser window title.
    public let titleKeywords: [String]
    public let defaultRule: SourceRule

    public init(name: String, bundlePrefixes: [String], titleKeywords: [String], defaultRule: SourceRule) {
        self.name = name
        self.bundlePrefixes = bundlePrefixes
        self.titleKeywords = titleKeywords
        self.defaultRule = defaultRule
    }

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

    /// The known source of a native app, else the matching app added by the user.
    public static func native(bundleID: String, custom: [CustomApp] = []) -> CallSource? {
        (known + custom.map(\.source)).first { s in s.bundlePrefixes.contains { bundleID.hasPrefix($0) } }
    }

    /// Source name for a process using the mic: the native app's source, or for a browser
    /// the normalized front window title, falling back to the browser name.
    /// nil for apps that are neither.
    public static func resolve(bundleID: String, windowTitle: String?, custom: [CustomApp] = [],
                               sites: [CustomWebsite] = []) -> String? {
        if let source = native(bundleID: bundleID, custom: custom) { return source.name }
        guard let browser = MeetingApp.match(bundleID: bundleID), browser.isBrowser else { return nil }
        return windowTitle.flatMap { normalizeBrowserTitle($0, sites: sites) } ?? browser.name
    }

    /// "(3) WhatsApp" → "WhatsApp", "Meet – abc-defg-hij – Google Chrome" → "Google Meet",
    /// "Chat | Microsoft Teams" → "Microsoft Teams". Unknown titles keep their first part.
    /// nil when nothing is left.
    /// Websites added by hand are checked after the known services.
    public static func normalizeBrowserTitle(_ title: String, sites: [CustomWebsite] = []) -> String? {
        let parts = titleParts(title)
        let candidates = known + sites.map(\.source)
        for part in parts {
            if let source = candidates.first(where: { $0.titleKeywords.contains { containsWords(part, $0) } }) {
                return source.name
            }
        }
        return parts.first
    }

    /// Title split on " – " / " - " / " — " / " | ", without the unread counter and
    /// the browser name. Empty parts are dropped, and so is Chrome's camera or microphone
    /// indicator with everything after it, which is the profile name.
    public static func titleParts(_ title: String) -> [String] {
        let parts = splitTitle(title)
        guard let indicator = parts.firstIndex(where: isMediaIndicator) else { return parts }
        return Array(parts[..<indicator])
    }

    private static func splitTitle(_ title: String) -> [String] {
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

    /// What Chrome adds to the window title while a tab uses the camera or microphone,
    /// e.g. "Weekly sync - Camera and microphone recording - Work".
    private static let mediaIndicators: Set<String> = [
        "camera and microphone recording", "camera or microphone recording",
        "microphone recording", "camera recording",
        "registrazione con videocamera e microfono", "registrazione con videocamera o microfono",
        "registrazione con microfono", "registrazione con videocamera",
    ]

    private static func isMediaIndicator(_ s: String) -> Bool { mediaIndicators.contains(s.lowercased()) }

    /// Whether `text` contains the words of `keyword` in a row, so "Meet" matches
    /// "Google Meet" but not "Meeting notes".
    private static func containsWords(_ text: String, _ keyword: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        let key = keyword.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !key.isEmpty, words.count >= key.count else { return false }
        return (0...(words.count - key.count)).contains { Array(words[$0..<($0 + key.count)]) == key }
    }
}

/// An app added by hand in Settings > Call Detection > Sources, detected by its bundle id.
public struct CustomApp: Codable, Equatable, Sendable {
    public let name: String
    public let bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }

    public var source: CallSource {
        CallSource(name: name, bundlePrefixes: [bundleID], titleKeywords: [], defaultRule: .always)
    }

    public enum AddResult: Equatable, Sendable {
        /// New app to add.
        case add(CustomApp)
        /// Already a known or added source, by that name.
        case existing(String)
        /// A browser: its calls are told apart by window title, not added as one source.
        case browser(String)
    }

    /// What adding the app with this bundle id and name should do.
    public static func adding(bundleID: String, name: String, to custom: [CustomApp]) -> AddResult {
        if let source = CallSource.native(bundleID: bundleID, custom: custom) { return .existing(source.name) }
        if let browser = MeetingApp.match(bundleID: bundleID), browser.isBrowser { return .browser(browser.name) }
        return .add(CustomApp(name: name, bundleID: bundleID))
    }
}

/// A website added by hand in Settings > Call Detection > Sources, recognized by words in the browser
/// window title.
public struct CustomWebsite: Codable, Equatable, Sendable {
    public let name: String
    /// Words to look for in the window title; the name when empty.
    public let keywords: [String]

    public init(name: String, keywords: [String] = []) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keywords = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public var source: CallSource {
        CallSource(name: name, bundlePrefixes: [], titleKeywords: keywords.isEmpty ? [name] : keywords, defaultRule: .always)
    }

    /// "Client Portal" and "portal, acme" → keywords ["portal", "acme"].
    public static func parseKeywords(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// A call noticed by call detection: its source and the app it runs in.
public struct DetectedCall: Equatable, Sendable {
    public let source: String
    /// e.g. "Google Chrome" for WhatsApp Web.
    public let app: String
    /// Raw title of the call window when the call started, if readable.
    public var windowTitle: String?

    public init(source: String, app: String, windowTitle: String? = nil) {
        self.source = source
        self.app = app
        self.windowTitle = windowTitle
    }
}

/// Always/Never choices saved per source name (case-insensitive).
public struct SourceRules: Codable, Equatable, Sendable {
    public private(set) var saved: [String: SourceRule]
    /// Sources recorded automatically when auto-recording is limited to chosen sources.
    public private(set) var autoRecord: [String]

    public init(_ saved: [String: SourceRule] = [:], autoRecord: [String] = []) {
        self.saved = saved
        self.autoRecord = autoRecord
    }

    private enum CodingKeys: String, CodingKey { case saved, autoRecord }

    /// Rules saved before auto-recording per source have no `autoRecord`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saved = try c.decodeIfPresent([String: SourceRule].self, forKey: .saved) ?? [:]
        autoRecord = try c.decodeIfPresent([String].self, forKey: .autoRecord) ?? []
    }

    public func autoRecords(_ source: String) -> Bool {
        autoRecord.contains { $0.caseInsensitiveCompare(source) == .orderedSame }
    }

    public mutating func setAutoRecord(_ on: Bool, for source: String) {
        autoRecord.removeAll { $0.caseInsensitiveCompare(source) == .orderedSame }
        if on { autoRecord.append(source) }
    }

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

    /// Drops the saved choice, so the default applies again.
    public mutating func forget(_ source: String) {
        for key in saved.keys where key.caseInsensitiveCompare(source) == .orderedSame { saved[key] = nil }
    }

    /// Sources to list in Settings: the known ones first, then apps added by hand and
    /// every other source seen or decided, alphabetically, without duplicates
    /// (case-insensitive). Removed sources are left out.
    public func listed(seen: [String], custom: [CustomApp] = [], sites: [CustomWebsite] = [],
                       removed: [String] = []) -> [String] {
        let others = (seen + saved.keys + custom.map(\.name) + sites.map(\.name))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var out: [String] = []
        for name in CallSource.known.map(\.name) + others
        where !(out + removed).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
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
