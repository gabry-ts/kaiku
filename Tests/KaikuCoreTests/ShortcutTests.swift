import XCTest
@testable import KaikuCore

final class ShortcutTests: XCTestCase {
    let hyper: KeyModifiers = [.control, .option, .command]

    func testDisplay() {
        XCTAssertEqual(KeyCombo(keyCode: 0x0F, modifiers: hyper).display, "⌃⌥⌘R")
        XCTAssertEqual(KeyCombo(keyCode: 0x31, modifiers: [.command, .option]).display, "⌥⌘Space")
        XCTAssertEqual(KeyCombo(keyCode: 0x60, modifiers: [.control]).display, "⌃F5")
        XCTAssertEqual(KeyCombo(keyCode: 0x7E, modifiers: [.command, .shift, .control, .option]).display, "⌃⌥⇧⌘↑")
        XCTAssertEqual(KeyCombo(keyCode: 0x31, modifiers: [.command]).displayParts, ["⌘", "Space"])
        XCTAssertEqual(KeyNames.name(for: 0x7B), "←")
        XCTAssertEqual(KeyNames.name(for: 0xFF), "Key 255")
    }

    func testModifiersAreCarbonValues() {
        XCTAssertEqual(KeyModifiers.command.rawValue, 0x100)
        XCTAssertEqual(KeyModifiers.shift.rawValue, 0x200)
        XCTAssertEqual(KeyModifiers.option.rawValue, 0x800)
        XCTAssertEqual(KeyModifiers.control.rawValue, 0x1000)
        // Unknown bits (e.g. caps lock) are dropped.
        XCTAssertEqual(KeyCombo(keyCode: 0, modifiers: KeyModifiers(rawValue: 0x100 | 0x400)).modifiers, .command)
    }

    func testRequiresModifier() {
        XCTAssertEqual(ShortcutRules.validate(KeyCombo(keyCode: 0x0F, modifiers: []), for: .record, in: [:]), .needsModifier)
        XCTAssertEqual(ShortcutRules.validate(KeyCombo(keyCode: 0x0F, modifiers: [.shift]), for: .record, in: [:]), .needsModifier)
        XCTAssertNil(ShortcutRules.validate(KeyCombo(keyCode: 0x0F, modifiers: [.shift, .option]), for: .record, in: [:]))
    }

    func testConflicts() {
        let r = KeyCombo(keyCode: 0x0F, modifiers: hyper)
        let assignments: [ShortcutAction: KeyCombo] = [.record: r, .pause: KeyCombo(keyCode: 0x23, modifiers: hyper)]
        XCTAssertEqual(ShortcutRules.validate(r, for: .showPanel, in: assignments), .usedBy(.record))
        // Assigning an action its own current combo is fine.
        XCTAssertNil(ShortcutRules.validate(r, for: .record, in: assignments))
        XCTAssertNil(ShortcutRules.conflict(KeyCombo(keyCode: 0x0F, modifiers: [.command, .option]), for: .pause, in: assignments))
    }

    func testDefaultsAndIDs() {
        XCTAssertEqual(ShortcutAction.record.defaultCombo?.display, "⌃⌥⌘R")
        XCTAssertEqual(ShortcutAction.pause.defaultCombo?.display, "⌃⌥⌘P")
        XCTAssertEqual(ShortcutAction.bookmark.defaultCombo?.display, "⌃⌥⌘B")
        XCTAssertNil(ShortcutAction.muteMicrophones.defaultCombo)
        XCTAssertNil(ShortcutAction.openLibrary.defaultCombo)
        XCTAssertNil(ShortcutAction.showPanel.defaultCombo)
        for a in ShortcutAction.allCases { XCTAssertEqual(ShortcutAction(hotKeyID: a.hotKeyID), a) }
        XCTAssertNil(ShortcutAction(hotKeyID: 0))
        XCTAssertNil(ShortcutAction(hotKeyID: 99))
    }

    func testStorageRoundTrip() {
        let c = KeyCombo(keyCode: 0x31, modifiers: [.command, .shift])
        XCTAssertEqual(ShortcutRules.decode(c.storage, default: nil), c)
        XCTAssertEqual(ShortcutRules.decode(nil, default: c), c)
        XCTAssertNil(ShortcutRules.decode([String: Int](), default: c))
        XCTAssertNil(ShortcutRules.decode(["keyCode": -1, "modifiers": 0], default: c))
    }

    func testLegacyPresets() {
        XCTAssertEqual(ShortcutRules.legacyCombo(for: .record, preset: "optCmdR")??.display, "⌥⌘R")
        XCTAssertEqual(ShortcutRules.legacyCombo(for: .record, preset: "ctrlOptCmdM")??.display, "⌃⌥⌘M")
        XCTAssertEqual(ShortcutRules.legacyCombo(for: .pause, preset: "ctrlCmd")??.display, "⌃⌘P")
        XCTAssertEqual(ShortcutRules.legacyCombo(for: .bookmark, preset: "ctrlOptCmd")??.display, "⌃⌥⌘B")
        XCTAssertEqual(ShortcutRules.legacyCombo(for: .record, preset: "off"), .some(nil))
        XCTAssertNil(ShortcutRules.legacyCombo(for: .record, preset: "bogus"))
        XCTAssertNil(ShortcutRules.legacyCombo(for: .showPanel, preset: "optCmd"))
    }
}
