import Foundation

/// Modifier keys of a shortcut. Raw values are the Carbon ones (`cmdKey`, `shiftKey`,
/// `optionKey`, `controlKey`), so they can be passed to RegisterEventHotKey as is.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 8)
    public static let shift = KeyModifiers(rawValue: 1 << 9)
    public static let option = KeyModifiers(rawValue: 1 << 11)
    public static let control = KeyModifiers(rawValue: 1 << 12)

    public static let all: KeyModifiers = [.command, .shift, .option, .control]

    /// In the order macOS shows them: ⌃⌥⇧⌘.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A key code (virtual key, `kVK_*`) with modifiers.
public struct KeyCombo: Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: KeyModifiers

    public init(keyCode: UInt32, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
    }

    /// Modifier symbols and key name, e.g. ["⌃", "⌥", "⌘", "Space"].
    public var displayParts: [String] {
        modifiers.symbols.map(String.init) + [KeyNames.name(for: keyCode)]
    }

    /// "⌃⌥⌘R", "⌥⌘Space", "⌃F5".
    public var display: String { displayParts.joined() }

    /// Stored in UserDefaults as ["keyCode": Int, "modifiers": Int].
    public var storage: [String: Int] { ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue)] }
}

/// US-layout names of virtual key codes, for display.
public enum KeyNames {
    static let names: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0A: "§", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O",
        0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Esc",
        0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +", 0x47: "Clear", 0x4B: "Keypad /",
        0x4C: "Enter", 0x4E: "Keypad -", 0x51: "Keypad =",
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3", 0x56: "Keypad 4",
        0x57: "Keypad 5", 0x58: "Keypad 6", 0x59: "Keypad 7", 0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14",
        0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x72: "Help", 0x73: "Home", 0x74: "Page Up", 0x75: "Forward Delete", 0x77: "End",
        0x79: "Page Down", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]

    public static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}

/// Global shortcuts the user can assign.
public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case record, pause, bookmark, muteMicrophones, openLibrary, showPanel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .record: return "Start or stop recording"
        case .pause: return "Pause or resume"
        case .bookmark: return "Add bookmark"
        case .muteMicrophones: return "Mute or unmute all microphones"
        case .openLibrary: return "Open recordings library"
        case .showPanel: return "Show panel"
        }
    }

    /// Carbon hot key id (stable, non-zero).
    public var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }

    public init?(hotKeyID: UInt32) {
        guard hotKeyID >= 1, Int(hotKeyID) <= Self.allCases.count else { return nil }
        self = Self.allCases[Int(hotKeyID) - 1]
    }

    public var defaultCombo: KeyCombo? {
        let mods: KeyModifiers = [.control, .option, .command]
        switch self {
        case .record: return KeyCombo(keyCode: 0x0F, modifiers: mods) // R
        case .pause: return KeyCombo(keyCode: 0x23, modifiers: mods) // P
        case .bookmark: return KeyCombo(keyCode: 0x0B, modifiers: mods) // B
        case .muteMicrophones, .openLibrary, .showPanel: return nil
        }
    }

    /// UserDefaults key of the assignment.
    public var settingsKey: String { "shortcut.\(rawValue)" }
}

public enum ShortcutRules {
    public enum Problem: Equatable, Sendable {
        /// No ⌘, ⌃ or ⌥ (Shift alone is not enough).
        case needsModifier
        /// Already assigned to another action.
        case usedBy(ShortcutAction)

        public var message: String {
            switch self {
            case .needsModifier: return "Use at least one of ⌘, ⌃ or ⌥."
            case .usedBy(let action): return "Already used for “\(action.title)”."
            }
        }
    }

    public static func hasRequiredModifier(_ combo: KeyCombo) -> Bool {
        !combo.modifiers.intersection([.command, .control, .option]).isEmpty
    }

    /// The other action that already uses `combo`, if any.
    public static func conflict(_ combo: KeyCombo, for action: ShortcutAction,
                                in assignments: [ShortcutAction: KeyCombo]) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && assignments[$0] == combo }
    }

    public static func validate(_ combo: KeyCombo, for action: ShortcutAction,
                                in assignments: [ShortcutAction: KeyCombo]) -> Problem? {
        if !hasRequiredModifier(combo) { return .needsModifier }
        if let other = conflict(combo, for: action, in: assignments) { return .usedBy(other) }
        return nil
    }

    /// Reads a stored assignment: nil value means "use the default", an empty dictionary
    /// means "None".
    public static func decode(_ value: Any?, default fallback: KeyCombo?) -> KeyCombo? {
        guard let dict = value as? [String: Any] else { return fallback }
        guard let key = (dict["keyCode"] as? NSNumber)?.intValue,
              let mods = (dict["modifiers"] as? NSNumber)?.intValue,
              key >= 0, mods >= 0 else { return nil }
        return KeyCombo(keyCode: UInt32(key), modifiers: KeyModifiers(rawValue: UInt32(mods)))
    }

    /// The assignment for the previous preset settings (`hotKey`, `pauseHotKey`,
    /// `bookmarkHotKey`), or nil when the preset is unknown. `.some(nil)` means "off".
    public static func legacyCombo(for action: ShortcutAction, preset: String) -> KeyCombo?? {
        let R: UInt32 = 0x0F, M: UInt32 = 0x2E
        if action == .record {
            switch preset {
            case "off": return .some(nil)
            case "ctrlOptCmdR": return KeyCombo(keyCode: R, modifiers: [.control, .option, .command])
            case "optCmdR": return KeyCombo(keyCode: R, modifiers: [.option, .command])
            case "ctrlCmdR": return KeyCombo(keyCode: R, modifiers: [.control, .command])
            case "ctrlOptCmdM": return KeyCombo(keyCode: M, modifiers: [.control, .option, .command])
            default: return nil
            }
        }
        guard action == .pause || action == .bookmark, let key = action.defaultCombo?.keyCode else { return nil }
        switch preset {
        case "off": return .some(nil)
        case "ctrlOptCmd": return KeyCombo(keyCode: key, modifiers: [.control, .option, .command])
        case "optCmd": return KeyCombo(keyCode: key, modifiers: [.option, .command])
        case "ctrlCmd": return KeyCombo(keyCode: key, modifiers: [.control, .command])
        default: return nil
        }
    }
}
