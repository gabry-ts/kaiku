import XCTest
@testable import KaikuCore

final class PopoverLayoutTests: XCTestCase {
    func testDefaultsAreTheStandardLayout() {
        XCTAssertEqual(PopoverLayout.defaults.map(\.section), [.record, .live, .mute, .status, .recovered, .recent])
        XCTAssertTrue(PopoverLayout.defaults.allSatisfy(\.isOn))
        XCTAssertEqual(PopoverLayout.visible(PopoverLayout.defaults), [.record, .live, .mute, .status, .recovered, .recent])
    }

    func testOnlyRecordIsLocked() {
        XCTAssertEqual(PopoverSection.allCases.filter(\.isLocked), [.record])
    }

    func testVisibleFollowsOrderAndSwitches() {
        let items = [PopoverItem(.record), PopoverItem(.recent), PopoverItem(.status, isOn: false),
                     PopoverItem(.mute), PopoverItem(.recovered, isOn: false)]
        XCTAssertEqual(PopoverLayout.visible(items), [.record, .recent, .mute])
    }

    func testRecordIsAlwaysShownFirst() {
        let items = [PopoverItem(.recent), PopoverItem(.record, isOn: false), PopoverItem(.mute)]
        XCTAssertEqual(PopoverLayout.settled(items), [PopoverItem(.record), PopoverItem(.recent), PopoverItem(.mute)])
        XCTAssertEqual(PopoverLayout.visible(items), [.record, .recent, .mute])
    }

    func testPopoverIsNeverEmpty() {
        let allOff = PopoverSection.allCases.map { PopoverItem($0, isOn: false) }
        XCTAssertEqual(PopoverLayout.visible(allOff), [.record])
        XCTAssertEqual(PopoverLayout.visible([]), [.record])
    }

    func testRoundTrip() {
        let items = [PopoverItem(.record), PopoverItem(.recent, isOn: false), PopoverItem(.mute)]
        XCTAssertEqual(PopoverLayout.decode(PopoverLayout.encode(items)), items)
    }

    func testDecodeSkipsUnknownSectionsAndBadData() {
        let saved = Data(#"[{"id":"recent","on":false},{"id":"weather","on":true},{"id":"mute","on":true}]"#.utf8)
        XCTAssertEqual(PopoverLayout.decode(saved), [PopoverItem(.recent, isOn: false), PopoverItem(.mute)])
        XCTAssertEqual(PopoverLayout.decode(nil), [])
        XCTAssertEqual(PopoverLayout.decode(Data("nope".utf8)), [])
    }

    func testLayoutSavedBeforeLiveStillReads() {
        let saved = Data(#"[{"id":"record","on":true},{"id":"recent","on":true},{"id":"mute","on":false}]"#.utf8)
        XCTAssertEqual(PopoverLayout.decode(saved), [PopoverItem(.record), PopoverItem(.recent), PopoverItem(.mute, isOn: false)])
    }

    func testRecentCount() {
        XCTAssertEqual(PopoverLayout.recentCount(3), 3)
        XCTAssertEqual(PopoverLayout.recentCount(8), 8)
        XCTAssertEqual(PopoverLayout.recentCount(0), 5)
        XCTAssertEqual(PopoverLayout.recentCount(4), 5)
    }
}
