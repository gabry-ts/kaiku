import XCTest
@testable import KaikuCore

final class LiveAssistTests: XCTestCase {
    func testTextHasTimeAndSpeaker() {
        var t = LiveTranscript()
        t.addFinal("Hello there", speaker: .me, start: 65, end: 67)
        t.addFinal("Hi", speaker: .them, start: 70, end: 71)
        XCTAssertEqual(LiveAssist.text(t.finals), "[00:01:05] Me: Hello there\n[00:01:10] Them: Hi")
    }

    func testLongTranscriptKeepsItsEndOnWholeLines() {
        var t = LiveTranscript()
        for i in 0..<50 { t.addFinal("line number \(i)", speaker: .me, start: Double(i), end: Double(i) + 1) }
        let text = LiveAssist.transcript(t.finals, limit: 200)
        XCTAssertTrue(text.hasPrefix("[Earlier part of the call left out]\n["))
        XCTAssertTrue(text.hasSuffix("line number 49"))
        XCTAssertFalse(text.contains("line number 0\n"))
        XCTAssertEqual(LiveAssist.transcript(t.finals), LiveAssist.text(t.finals))
    }

    func testPendingSkipsPartialsAndSummarizedLines() {
        var t = LiveTranscript()
        t.addFinal("First", speaker: .me, start: 1, end: 2)
        t.addFinal("Third", speaker: .me, start: 10, end: 11)
        t.setPartial("still talking", speaker: .them, at: 12)
        let summarized = Set(t.finals.map(\.id))
        XCTAssertTrue(LiveAssist.pending(t, summarized: summarized).isEmpty)
        // A late final from the other track lands between lines already summarized.
        t.addFinal("Second", speaker: .them, start: 5, end: 6)
        XCTAssertEqual(LiveAssist.pending(t, summarized: summarized).map(\.text), ["Second"])
        XCTAssertEqual(LiveAssist.wordCount(t.finals), 3)
    }

    func testPace() {
        XCTAssertFalse(LiveAssist.shouldSummarize(pendingWords: 200, sinceLast: 30))
        XCTAssertFalse(LiveAssist.shouldSummarize(pendingWords: 40, sinceLast: 60))
        XCTAssertTrue(LiveAssist.shouldSummarize(pendingWords: 80, sinceLast: 45))
        XCTAssertFalse(LiveAssist.shouldSummarize(pendingWords: 10, sinceLast: 300))
        XCTAssertTrue(LiveAssist.shouldSummarize(pendingWords: 15, sinceLast: 120))
    }

    func testSummaryPromptSendsBulletsAndNewLinesOnly() {
        let p = LiveAssist.summaryPrompt(bullets: ["Roadmap for Q4"], newLines: "[00:00:30] Them: Billing slips a week")
        XCTAssertTrue(p.contains("Current bullets:\n- Roadmap for Q4"))
        XCTAssertTrue(p.hasSuffix("New lines:\n[00:00:30] Them: Billing slips a week"))
        XCTAssertTrue(LiveAssist.summaryPrompt(bullets: [], newLines: "x").contains("(none yet)"))
    }

    func testAskPromptIsGroundedWithRecentHistory() {
        let history = (1...5).map { LiveAssist.Exchange(id: $0, question: "q\($0)", answer: "a\($0)") }
            + [LiveAssist.Exchange(id: 6, question: "waiting")]
        let p = LiveAssist.askPrompt(transcript: "[00:00:01] Me: Hi", history: history, question: "Who said hi?")
        XCTAssertTrue(p.contains(LiveAssist.notMentioned))
        XCTAssertTrue(p.contains("Transcript:\n[00:00:01] Me: Hi"))
        XCTAssertTrue(p.hasSuffix("Question: Who said hi?"))
        XCTAssertFalse(p.contains("q3"))
        XCTAssertTrue(p.contains("Q: q4\nA: a4"))
        XCTAssertTrue(p.contains("Q: q5\nA: a5"))
        XCTAssertFalse(p.contains("waiting"))
        XCTAssertFalse(LiveAssist.askPrompt(transcript: "", history: [], question: "x").contains("Earlier questions"))
    }

    func testParseBullets() {
        let reply = "Here is the list:\n## Summary\n- One\n* Two\n  • Three\n-\n**Bold heading**\n- "
        XCTAssertEqual(LiveAssist.parseBullets(reply), ["One", "Two", "Three"])
        XCTAssertEqual(LiveAssist.parseBullets("- a\n- b\n- c", limit: 2), ["a", "b"])
        XCTAssertTrue(LiveAssist.parseBullets("No bullets here").isEmpty)
        XCTAssertEqual(LiveAssist.markdown(["a", "b"]), "- a\n- b")
    }
}
