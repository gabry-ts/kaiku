import XCTest
@testable import KaikuCore

final class CallTitleTests: XCTestCase {
    func testMeaningfulTitlesAreKept() {
        XCTAssertEqual(CallTitle.clean("Weekly sync | Microsoft Teams", source: "Microsoft Teams"), "Weekly sync")
        XCTAssertEqual(CallTitle.clean("Huddle in #design", source: "Slack"), "Huddle in #design")
        XCTAssertEqual(CallTitle.clean("Anna Rossi", source: "FaceTime"), "Anna Rossi")
        XCTAssertEqual(CallTitle.clean("(2) Anna - WhatsApp", source: "WhatsApp"), "Anna")
        XCTAssertEqual(CallTitle.clean("Meet – Weekly sync – Google Chrome", source: "Google Meet"), "Weekly sync")
        XCTAssertEqual(CallTitle.clean("Q4 - planning | Microsoft Teams", source: "Microsoft Teams"), "Q4 - planning")
    }

    func testGenericTitlesAreDropped() {
        XCTAssertNil(CallTitle.clean("Zoom Meeting", source: "Zoom"))
        XCTAssertNil(CallTitle.clean("Zoom Workplace", source: "Zoom"))
        XCTAssertNil(CallTitle.clean("Meet – abc-defg-hij", source: "Google Meet"))
        XCTAssertNil(CallTitle.clean("Microsoft Teams", source: "Microsoft Teams"))
        XCTAssertNil(CallTitle.clean("(5) WhatsApp", source: "WhatsApp"))
        XCTAssertNil(CallTitle.clean("  ", source: "Zoom"))
        XCTAssertNil(CallTitle.clean("Client Portal - Google Chrome", source: "Client Portal"))
    }

    func testChromeRecordingIndicatorAndProfileAreDropped() {
        XCTAssertEqual(CallTitle.clean("Matteo / Luca - Registrazione con videocamera e microfono - Luca (shellonback.com)", source: "Google Meet"),
                       "Matteo / Luca")
        XCTAssertEqual(CallTitle.clean("Meet – Weekly sync - Camera and microphone recording - Work", source: "Google Meet"), "Weekly sync")
        XCTAssertNil(CallTitle.clean("Meet – abc-defg-hij - Microphone recording - Work", source: "Google Meet"))
    }

    func testLongTitlesAreCut() {
        let long = String(repeating: "a", count: 150)
        XCTAssertEqual(CallTitle.clean(long, source: "Zoom")?.count, 100)
        XCTAssertEqual(CallTitle.clean("Line one\nline two", source: "Zoom"), "Line one line two")
    }

    func testTitleOrder() {
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 23, hour: 14, minute: 30).date!
        XCTAssertEqual(CallTitle.choose(eventTitle: "Design review", windowTitle: "Weekly sync | Microsoft Teams",
                                        source: "Microsoft Teams", date: date), "Design review")
        XCTAssertEqual(CallTitle.choose(eventTitle: " ", windowTitle: "Weekly sync | Microsoft Teams",
                                        source: "Microsoft Teams", date: date), "Weekly sync")
        XCTAssertEqual(CallTitle.choose(eventTitle: nil, windowTitle: "Zoom Meeting", source: "Zoom", date: date),
                       "Zoom call 2026-09-23 14:30")
        XCTAssertEqual(CallTitle.choose(eventTitle: nil, windowTitle: nil, source: "WhatsApp", date: date),
                       "WhatsApp call 2026-09-23 14:30")
    }
}
