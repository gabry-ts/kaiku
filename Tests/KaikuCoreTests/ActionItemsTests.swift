import XCTest
@testable import KaikuCore

final class ActionItemsTests: XCTestCase {
    func testSplitReadsTrailingJSONBlock() {
        let response = """
        ## Summary
        Talked.

        ```json
        {"action_items": [
          {"text": " Send the quote ", "owner": "Me", "due": "2026-10-09"},
          {"text": "Book a room", "owner": null, "due": "next week"},
          {"text": "  "}
        ]}
        ```
        """
        let (markdown, items) = ActionItems.split(response)
        XCTAssertEqual(markdown, "## Summary\nTalked.")
        XCTAssertEqual(items.map(\.text), ["Send the quote", "Book a room"])
        XCTAssertEqual(items[0].owner, "Me")
        XCTAssertEqual(items[0].due, "2026-10-09")
        XCTAssertNil(items[1].owner)
        XCTAssertNil(items[1].due)
    }

    func testSplitAcceptsBareArray() {
        let (_, items) = ActionItems.split("Text\n```JSON\n[{\"text\": \"Call Anna\"}]\n```\n")
        XCTAssertEqual(items.map(\.text), ["Call Anna"])
    }

    func testMissingOrInvalidBlockGivesNoItems() {
        XCTAssertEqual(ActionItems.split("## Summary\nOnly text.").items, [])
        XCTAssertEqual(ActionItems.split("## Summary\nOnly text.").markdown, "## Summary\nOnly text.")
        let broken = ActionItems.split("## Summary\n```json\n{not json\n```")
        XCTAssertEqual(broken.items, [])
        XCTAssertEqual(broken.markdown, "## Summary")
        // A block that is not at the end belongs to the summary.
        let middle = ActionItems.split("```json\n{}\n```\nMore text")
        XCTAssertEqual(middle.markdown, "```json\n{}\n```\nMore text")
    }

    func testInvalidDatesAreDropped() {
        let (_, items) = ActionItems.split("```json\n[{\"text\":\"a\",\"due\":\"2026-02-30\"},{\"text\":\"b\",\"due\":\"2026-2-3\"}]\n```")
        XCTAssertEqual(items.map(\.due), [nil, nil])
        XCTAssertEqual(ActionItems.dueComponents("2026-10-09"), DateComponents(year: 2026, month: 10, day: 9))
        XCTAssertNil(ActionItems.dueComponents("soon"))
    }

    func testOwnerMatching() {
        XCTAssertTrue(ActionItems.isOwnedByUser("me", meLabel: "Gabriele"))
        XCTAssertTrue(ActionItems.isOwnedByUser(" gabriele ", meLabel: "Gabriele"))
        XCTAssertFalse(ActionItems.isOwnedByUser("Anna", meLabel: "Gabriele"))
        XCTAssertFalse(ActionItems.isOwnedByUser(nil, meLabel: "Me"))
        XCTAssertFalse(ActionItems.isOwnedByUser("  ", meLabel: "Me"))
    }

    func testMergeKeepsSentMarks() {
        let old = [ActionItem(text: "Send quote", sentTo: [.things])]
        let merged = ActionItems.merge([ActionItem(text: "send quote"), ActionItem(text: "Other")], keepingSentFrom: old)
        XCTAssertEqual(merged.map(\.sentTo), [[.things], []])
    }

    func testNotes() {
        XCTAssertEqual(ActionItems.notes(callTitle: "Plan", date: "2026-10-03"), "Plan\n2026-10-03")
        XCTAssertEqual(ActionItems.notes(callTitle: "", date: "d", extra: "/p"), "Call\nd\n/p")
    }

    func testCodableRoundTrip() throws {
        let item = ActionItem(text: "x", owner: "Me", due: "2026-10-09", sentTo: [.linear])
        let back = try JSONDecoder().decode(ActionItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)
    }
}
