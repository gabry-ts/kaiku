import XCTest
@testable import KaikuCore

final class LiveTranscriptTests: XCTestCase {
    func testPartialIsRewrittenPerTrack() {
        var t = LiveTranscript()
        XCTAssertTrue(t.isEmpty)
        t.setPartial("Good", speaker: .me, at: 1)
        t.setPartial("Good morning", speaker: .me, at: 1.5)
        t.setPartial("Hi", speaker: .them, at: 2)
        XCTAssertEqual(t.lines.map(\.text), ["Good morning", "Hi"])
        XCTAssertEqual(t.lines.map(\.speaker), [.me, .them])
        XCTAssertEqual(t.lines.map(\.start), [1, 2])
        XCTAssertTrue(t.lines.allSatisfy { !$0.isFinal })
        XCTAssertTrue(t.finals.isEmpty)
    }

    func testEmptyPartialRemovesTheLine() {
        var t = LiveTranscript()
        t.setPartial("Hello", speaker: .me, at: 1)
        t.setPartial("  ", speaker: .me, at: 2)
        XCTAssertTrue(t.isEmpty)
    }

    func testFinalReplacesThePartialOfItsTrackOnly() {
        var t = LiveTranscript()
        t.setPartial("Good mor", speaker: .me, at: 1)
        t.setPartial("Hi", speaker: .them, at: 2)
        let id = t.lines[0].id
        t.addFinal(" Good morning. ", speaker: .me, start: 1, end: 3)
        XCTAssertEqual(t.finals.map(\.text), ["Good morning."])
        XCTAssertEqual(t.finals[0].id, id)
        XCTAssertEqual(t.lines.map(\.text), ["Good morning.", "Hi"])
        XCTAssertEqual(t.lines.map(\.isFinal), [true, false])
    }

    func testFinalsStayInTimeOrderAcrossTracks() {
        var t = LiveTranscript()
        t.addFinal("First", speaker: .me, start: 1, end: 2)
        t.addFinal("Third", speaker: .me, start: 9, end: 10)
        // The other track reports later about something said earlier.
        t.addFinal("Second", speaker: .them, start: 4, end: 6)
        t.addFinal("Same time", speaker: .them, start: 9, end: 11)
        XCTAssertEqual(t.finals.map(\.text), ["First", "Second", "Third", "Same time"])
        XCTAssertEqual(Set(t.finals.map(\.id)).count, 4)
    }

    func testEmptyFinalOnlyClearsThePartial() {
        var t = LiveTranscript()
        t.setPartial("Hm", speaker: .me, at: 1)
        t.addFinal("", speaker: .me, start: 1, end: 2)
        XCTAssertTrue(t.isEmpty)
    }

    func testLastLines() {
        var t = LiveTranscript()
        for i in 0..<5 { t.addFinal("Line \(i)", speaker: i % 2 == 0 ? .me : .them, start: Double(i), end: Double(i) + 1) }
        t.setPartial("Now", speaker: .me, at: 6)
        XCTAssertEqual(t.lastLines(3).map(\.text), ["Line 3", "Line 4", "Now"])
        XCTAssertEqual(t.lastLines(20).count, 6)
        XCTAssertEqual(t.lastLines(0), [])
    }

    func testFinalizePartials() {
        var t = LiveTranscript()
        t.addFinal("Done", speaker: .me, start: 1, end: 2)
        t.setPartial("Still talking", speaker: .them, at: 3)
        t.setPartial("Me too", speaker: .me, at: 4)
        t.finalizePartials()
        XCTAssertEqual(t.finals.map(\.text), ["Done", "Still talking", "Me too"])
        XCTAssertTrue(t.lines.allSatisfy(\.isFinal))
    }

    func testSegmentsComeFromFinalsWithSpeakers() {
        var t = LiveTranscript()
        t.addFinal("Hello there.", speaker: .me, start: 1, end: 2.5)
        t.addFinal("Hi!", speaker: .them, start: 3, end: 3.5)
        t.setPartial("not yet", speaker: .me, at: 5)
        XCTAssertEqual(t.segments(), [
            Segment(start: 1, end: 2.5, speaker: "Me", text: "Hello there."),
            Segment(start: 3, end: 3.5, speaker: "Them", text: "Hi!"),
        ])
        let result = t.result(language: "en")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertTrue(TranscriptFormatter.merge(result.segments).count == 2)
    }

    func testTimelineFollowsTheRecording() {
        var line = LiveTimeline()
        XCTAssertEqual(line.recordedTime(3), 3)
        // Fed back to back from 0.5 s into the recording.
        line.note(recorded: 0.5, duration: 1)
        line.note(recorded: 1.5, duration: 1)
        XCTAssertEqual(line.recordedTime(1.2), 1.7, accuracy: 0.001)
        // Four seconds of silence were added to the file: the engine never heard them.
        line.note(recorded: 6.5, duration: 1)
        XCTAssertEqual(line.recordedTime(1.9), 2.4, accuracy: 0.001)
        XCTAssertEqual(line.recordedTime(2.5), 7, accuracy: 0.001)
        // Small rounding differences don't add jumps.
        line.note(recorded: 7.52, duration: 1)
        XCTAssertEqual(line.recordedTime(3.5), 8, accuracy: 0.001)
    }
}
