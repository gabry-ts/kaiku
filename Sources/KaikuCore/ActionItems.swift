import Foundation

/// Where an action item can be sent.
public enum ActionDestination: String, Codable, CaseIterable, Sendable {
    case reminders, things, linear

    public var displayName: String {
        switch self {
        case .reminders: return "Reminders"
        case .things: return "Things"
        case .linear: return "Linear"
        }
    }
}

/// One task taken from a call, saved in action-items.json.
public struct ActionItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    /// Who has to do it, as named in the transcript.
    public var owner: String?
    /// Due day as `yyyy-MM-dd`.
    public var due: String?
    /// Destinations it was already sent to.
    public var sentTo: [ActionDestination]

    public init(id: String = UUID().uuidString, text: String, owner: String? = nil, due: String? = nil,
                sentTo: [ActionDestination] = []) {
        self.id = id
        self.text = text
        self.owner = owner
        self.due = due
        self.sentTo = sentTo
    }
}

/// Asks the model for a structured list of action items and reads it back.
public enum ActionItems {
    /// Appended to the summary prompt. The JSON block comes after the Markdown summary.
    public static func promptSuffix(callDate: String) -> String {
        """


        After the Markdown summary, add one fenced code block tagged json with the action items as \
        {"action_items": [{"text": "...", "owner": "...", "due": "YYYY-MM-DD"}]}. \
        Use the owner's name as it appears in the transcript, and leave out "owner" or "due" when unknown. \
        Only give a due date when the call states one; the call took place on \(callDate). \
        Use an empty list when there are none. Write the text in the language of the transcript.
        """
    }

    private struct Envelope: Decodable { let action_items: [Raw] }
    private struct Raw: Decodable {
        let text: String?
        let owner: String?
        let due: String?
    }

    /// Separates the trailing json block from the Markdown. A missing or invalid block gives no items.
    public static func split(_ response: String) -> (markdown: String, items: [ActionItem]) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.range(of: "```json", options: [.caseInsensitive, .backwards]),
              let close = trimmed.range(of: "```", range: open.upperBound..<trimmed.endIndex),
              trimmed[close.upperBound...].allSatisfy(\.isWhitespace) else {
            return (trimmed, [])
        }
        let markdown = trimmed[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let json = Data(trimmed[open.upperBound..<close.lowerBound].utf8)
        let raws = (try? JSONDecoder().decode(Envelope.self, from: json))?.action_items
            ?? (try? JSONDecoder().decode([Raw].self, from: json)) ?? []
        let items = raws.compactMap { raw -> ActionItem? in
            let text = (raw.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ActionItem(text: text, owner: clean(raw.owner), due: validDay(clean(raw.due)))
        }
        return (markdown, items)
    }

    /// Keeps the sent marks of items whose text is unchanged, for a regenerated list.
    public static func merge(_ new: [ActionItem], keepingSentFrom old: [ActionItem]) -> [ActionItem] {
        new.map { item in
            var item = item
            if let match = old.first(where: { $0.text.lowercased() == item.text.lowercased() }) { item.sentTo = match.sentTo }
            return item
        }
    }

    /// True when the owner is you: your name in Settings, or "me". An empty owner is not.
    public static func isOwnedByUser(_ owner: String?, meLabel: String) -> Bool {
        guard let owner = clean(owner)?.lowercased() else { return false }
        return owner == "me" || owner == meLabel.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The `yyyy-MM-dd` day as calendar components, nil when it is not a real day.
    public static func dueComponents(_ due: String?) -> DateComponents? {
        guard let due = validDay(due) else { return nil }
        let parts = due.split(separator: "-").compactMap { Int($0) }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Text for the notes or description of the created task.
    public static func notes(callTitle: String, date: String, extra: String? = nil) -> String {
        ([callTitle.isEmpty ? "Call" : callTitle, date] + [extra].compactMap { $0 }).joined(separator: "\n")
    }

    static func clean(_ s: String?) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.lowercased() == "null" ? nil : t
    }

    /// The string itself when it is a real `yyyy-MM-dd` day.
    static func validDay(_ s: String?) -> String? {
        guard let s else { return nil }
        let pieces = s.split(separator: "-")
        let parts = pieces.compactMap { Int($0) }
        guard parts.count == 3, pieces.map(\.count) == [4, 2, 2] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return s
    }
}
