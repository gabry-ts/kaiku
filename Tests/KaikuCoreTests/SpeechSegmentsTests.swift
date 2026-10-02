import XCTest
@testable import KaikuCore

final class SpeechSegmentsTests: XCTestCase {
    private typealias Run = RecognizedSpeech.Run
    private typealias Word = Segment.Word

    func testOneSegmentPerSentenceWithRunTimes() {
        let result = RecognizedSpeech(start: 0, end: 6, runs: [
            Run("Good", start: 0.4, end: 0.7), Run(" "), Run("morning.", start: 0.7, end: 1.3), Run(" "),
            Run("Shall", start: 2.1, end: 2.4), Run(" "), Run("we", start: 2.4, end: 2.5), Run(" "), Run("start?", start: 2.5, end: 3.2),
        ])
        XCTAssertEqual(SpeechSegments.segments(from: [result]), [
            Segment(start: 0.4, end: 1.3, text: "Good morning.",
                    words: [Word(start: 0.4, end: 0.7, text: "Good"), Word(start: 0.7, end: 1.3, text: "morning.")]),
            Segment(start: 2.1, end: 3.2, text: "Shall we start?",
                    words: [Word(start: 2.1, end: 2.4, text: "Shall"), Word(start: 2.4, end: 2.5, text: "we"),
                            Word(start: 2.5, end: 3.2, text: "start?")]),
        ])
    }

    func testResultWithoutRunTimesKeepsItsRange() {
        let result = RecognizedSpeech(start: 12, end: 15.5, runs: [Run(" See you on Monday ")])
        XCTAssertEqual(SpeechSegments.segments(from: [result]), [Segment(start: 12, end: 15.5, text: "See you on Monday")])
    }

    func testUntimedSentencesFollowEachOtherAndEndWithTheResult() {
        let result = RecognizedSpeech(start: 3, end: 9, runs: [Run("Yes. "), Run("Fine.")])
        XCTAssertEqual(SpeechSegments.segments(from: [result]), [
            Segment(start: 3, end: 3, text: "Yes."),
            Segment(start: 3, end: 9, text: "Fine."),
        ])
    }

    func testTextAfterTheLastSentenceEndIsKept() {
        let result = RecognizedSpeech(start: 0, end: 5, runs: [
            Run("Okay.", start: 0.2, end: 0.8), Run(" and then", start: 1.5, end: 2.4),
        ])
        XCTAssertEqual(SpeechSegments.segments(from: [result]), [
            Segment(start: 0.2, end: 0.8, text: "Okay.", words: [Word(start: 0.2, end: 0.8, text: "Okay.")]),
            Segment(start: 1.5, end: 2.4, text: "and then", words: [Word(start: 1.5, end: 2.4, text: "and then")]),
        ])
    }

    func testEmptyResultsAreSkipped() {
        let results = [
            RecognizedSpeech(start: 0, end: 1, runs: []),
            RecognizedSpeech(start: 1, end: 2, runs: [Run("  "), Run("\n")]),
            RecognizedSpeech(start: 2, end: 4, runs: [Run("Hello", start: 2.5, end: 3)]),
        ]
        XCTAssertEqual(SpeechSegments.segments(from: results),
                       [Segment(start: 2.5, end: 3, text: "Hello", words: [Word(start: 2.5, end: 3, text: "Hello")])])
    }

    func testTimesThatAreNotNumbersFallBack() {
        let results = [
            RecognizedSpeech(start: 1, end: 2, runs: [Run("One", start: .nan, end: 1.5)]),
            RecognizedSpeech(start: .nan, end: .infinity, runs: [Run("Two")]),
            RecognizedSpeech(start: 5, end: 6, runs: [Run("Three", start: 5.8, end: 5.2)]),
        ]
        XCTAssertEqual(SpeechSegments.segments(from: results), [
            Segment(start: 1, end: 2, text: "One"),
            Segment(start: 2, end: 2, text: "Two"),
            Segment(start: 5, end: 6, text: "Three"),
        ])
    }

    func testResultsStayInOrder() {
        let results = [
            RecognizedSpeech(start: 0, end: 2, runs: [Run("First.", start: 0.1, end: 1)]),
            RecognizedSpeech(start: 2, end: 4, runs: [Run("Second.", start: 2.2, end: 3)]),
        ]
        XCTAssertEqual(SpeechSegments.segments(from: results).map(\.text), ["First.", "Second."])
    }
}
