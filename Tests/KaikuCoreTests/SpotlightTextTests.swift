import XCTest
@testable import KaikuCore

final class SpotlightTextTests: XCTestCase {
    private let transcript = """
    # Weekly sync

    **[00:00:01] Anna:** Hello   everyone, let's start.

    **[00:00:09] Marco:** Sure, the budget first.
    """

    func testSnippetKeepsOnlySpeech() {
        XCTAssertEqual(SpotlightText.snippet(fromTranscript: transcript),
                       "Hello everyone, let's start. Sure, the budget first.")
    }

    func testSnippetCutsBetweenWords() {
        XCTAssertEqual(SpotlightText.snippet(fromTranscript: transcript, limit: 20), "Hello everyone,")
    }

    func testSnippetOfPlainTextIsEmpty() {
        XCTAssertEqual(SpotlightText.snippet(fromTranscript: "nothing here"), "")
    }
}
