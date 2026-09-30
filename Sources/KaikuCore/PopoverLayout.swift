import Foundation

/// A section of the menu bar popover. Adding a case adds it to the settings list and,
/// for people who already arranged theirs, to the end of their saved order.
public enum PopoverSection: String, CaseIterable, Codable, Sendable {
    /// The Start Recording button, or the card of the recording in progress.
    case record
    /// The Mute all microphones switch.
    case mute
    /// Progress and result of the transcription.
    case status
    /// Calls saved after an interruption.
    case recovered
    /// The latest calls.
    case recent

    /// Locked sections are always shown and keep their place.
    public var isLocked: Bool { self == .record }
}

/// A section with whether it is shown.
public struct PopoverItem: Identifiable, Codable, Equatable, Sendable {
    public let section: PopoverSection
    public var isOn: Bool
    public var id: String { section.rawValue }

    public init(_ section: PopoverSection, isOn: Bool = true) {
        self.section = section
        self.isOn = isOn
    }
}

/// What the popover shows and in which order.
public enum PopoverLayout {
    /// Every section, shown, in the standard order.
    public static let defaults: [PopoverItem] = PopoverSection.allCases.map { PopoverItem($0) }

    public static let recentCounts = [3, 5, 8]
    public static let defaultRecentCount = 5

    /// The saved number of recent calls, or the default when it isn't one of the choices.
    public static func recentCount(_ saved: Int) -> Int {
        recentCounts.contains(saved) ? saved : defaultRecentCount
    }

    /// `items` with the locked sections switched on and moved to the front, in their
    /// standard order, so the popover always opens with them.
    public static func settled(_ items: [PopoverItem]) -> [PopoverItem] {
        let locked = defaults.filter(\.section.isLocked)
        return locked + items.filter { !$0.section.isLocked }
    }

    /// The sections to show, in order.
    public static func visible(_ items: [PopoverItem]) -> [PopoverSection] {
        settled(items).filter(\.isOn).map(\.section)
    }

    public static func encode(_ items: [PopoverItem]) -> Data {
        let stored = items.map { Stored(id: $0.section.rawValue, on: $0.isOn) }
        return (try? JSONEncoder().encode(stored)) ?? Data()
    }

    /// The saved items as they were written. Sections this version doesn't know are
    /// skipped; nothing saved, or unreadable data, is an empty list.
    public static func decode(_ data: Data?) -> [PopoverItem] {
        guard let data, let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.compactMap { s in PopoverSection(rawValue: s.id).map { PopoverItem($0, isOn: s.on) } }
    }

    /// Sections are stored by name, so a list saved by another version still reads.
    private struct Stored: Codable {
        let id: String
        let on: Bool
    }
}
