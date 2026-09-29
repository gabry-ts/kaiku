import Foundation

/// Title of an auto-detected recording: calendar event, else the call window title,
/// else "<Source> call <date>".
public enum CallTitle {
    public static func choose(eventTitle: String?, windowTitle: String?, source: String, date: Date) -> String {
        if let e = eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty { return e }
        return windowTitle.flatMap { clean($0, source: source) } ?? fallback(source: source, date: date)
    }

    /// "Zoom call 2026-09-23 14:30".
    public static func fallback(source: String, date: Date) -> String {
        "\(source) call \(Naming.defaultTitle(date: date).dropFirst(5))"
    }

    /// The meaningful part of a call window title, or nil when it's generic:
    /// "Weekly sync | Microsoft Teams" → "Weekly sync", "Meet – abc-defg-hij" → nil,
    /// "Zoom Meeting" → nil, "(2) Anna - WhatsApp" → "Anna".
    public static func clean(_ title: String, source: String) -> String? {
        let parts = CallSource.titleParts(title.components(separatedBy: .newlines).joined(separator: " "))
            .filter { !isGeneric($0, source: source) }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " - ")
        return joined.count > maxLength ? String(joined.prefix(maxLength)).trimmingCharacters(in: .whitespaces) : joined
    }

    static let maxLength = 100

    private static let genericTitles: Set<String> = [
        "zoom meeting", "zoom workplace", "zoom cloud meetings", "zoom", "meet", "google meet",
        "microsoft teams", "whatsapp", "telegram", "facetime", "phone", "slack", "webex",
        "discord", "signal", "viber", "element", "whereby", "jitsi meet", "ringcentral", "goto meeting",
        "meeting", "call", "new tab",
    ]

    private static func isGeneric(_ part: String, source: String) -> Bool {
        let p = part.lowercased()
        if genericTitles.contains(p) || p == source.lowercased() { return true }
        if CallSource.known.contains(where: { $0.name.lowercased() == p || $0.titleKeywords.contains { $0.lowercased() == p } }) {
            return true
        }
        // A bare Google Meet code, e.g. "abc-defg-hij".
        return p.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil
    }
}
