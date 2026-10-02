import XCTest
@testable import KaikuCore

final class PlaybackTranscriptTests: XCTestCase {
    private typealias Word = Segment.Word

    func testLinesFollowTurnsWithWordAndPhraseSpans() {
        let lines = PlaybackTranscript.lines(from: [
            Segment(start: 0, end: 1, speaker: "Me", text: "Ciao, Anna.",
                    words: [Word(start: 0, end: 0.4, text: "Ciao"), Word(start: 0.5, end: 1, text: "Anna")]),
            Segment(start: 1.5, end: 3, speaker: "Me", text: " Come va? "),
            Segment(start: 4, end: 5, speaker: nil, text: "Bene."),
        ])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Ciao, Anna. Come va?")
        XCTAssertEqual(lines[0].end, 3)
        XCTAssertEqual(lines[0].spans, [
            PlaybackSpan(start: 0, end: 0.4, range: 0..<4, isWord: true),
            PlaybackSpan(start: 0.5, end: 1, range: 6..<10, isWord: true),
            PlaybackSpan(start: 1.5, end: 3, range: 12..<20, isWord: false),
        ])
        XCTAssertEqual(lines[1].speaker, "Unknown")
        XCTAssertEqual(lines[1].spans, [PlaybackSpan(start: 4, end: 5, range: 0..<5, isWord: false)])
    }

    func testPositionFindsTheWordBeingSaid() {
        let lines = PlaybackTranscript.lines(from: [
            Segment(start: 1, end: 2, speaker: "Me", text: "uno due",
                    words: [Word(start: 1, end: 1.4, text: "uno"), Word(start: 1.5, end: 2, text: "due")]),
            Segment(start: 10, end: 12, speaker: "Others", text: "tre"),
        ])
        XCTAssertNil(PlaybackTranscript.position(at: 0.5, in: lines))
        XCTAssertEqual(PlaybackTranscript.position(at: 1.2, in: lines), .init(line: 0, span: 0))
        XCTAssertEqual(PlaybackTranscript.position(at: 1.7, in: lines), .init(line: 0, span: 1))
        XCTAssertEqual(PlaybackTranscript.position(at: 2.5, in: lines), .init(line: 0, span: 1))
        XCTAssertNil(PlaybackTranscript.position(at: 5, in: lines))
        XCTAssertEqual(PlaybackTranscript.position(at: 11, in: lines), .init(line: 1, span: 0))
        XCTAssertNil(PlaybackTranscript.position(at: 20, in: lines))
    }

    func testPositionInOverlappingLinesTakesTheOneStillGoing() {
        let lines = PlaybackTranscript.lines(from: [
            Segment(start: 0, end: 20, speaker: "Me", text: "lungo"),
            Segment(start: 5, end: 6, speaker: "Others", text: "breve"),
        ])
        XCTAssertEqual(PlaybackTranscript.position(at: 5.5, in: lines)?.line, 1)
        XCTAssertEqual(PlaybackTranscript.position(at: 10, in: lines)?.line, 0)
    }

    func testSeekTimeForACharacter() {
        let line = PlaybackTranscript.lines(from: [
            Segment(start: 3, end: 5, text: "Ciao, Anna.",
                    words: [Word(start: 3.1, end: 3.5, text: "Ciao"), Word(start: 4, end: 5, text: "Anna")]),
        ])[0]
        XCTAssertEqual(line.seekTime(atCharacter: 2), 3.1)
        XCTAssertEqual(line.seekTime(atCharacter: 5), 3.1) // the space after "Ciao,"
        XCTAssertEqual(line.seekTime(atCharacter: 8), 4)
    }

    func testLinesFromTranscriptBlocks() {
        let lines = PlaybackTranscript.lines(from: [
            TranscriptBlock(start: 2, speaker: "Me", text: "Ciao"),
            TranscriptBlock(start: 7, speaker: "Others", text: "Salve"),
        ])
        XCTAssertEqual(lines[0].spans, [PlaybackSpan(start: 2, end: 7, range: 0..<4, isWord: false)])
        XCTAssertEqual(PlaybackTranscript.position(at: 30, in: lines), .init(line: 1, span: 0))
    }

    func testLocateSkipsWordsNotInTheText() {
        XCTAssertEqual(PlaybackTranscript.locate(["perché", "xyz", "così"], in: "Perche, è così."), [0..<6, nil, 10..<14])
    }
}
