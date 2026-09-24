import XCTest
@testable import KaikuCore

final class TranscriptTests: XCTestCase {
    func testTimestamp() {
        XCTAssertEqual(TranscriptFormatter.timestamp(0), "00:00:00")
        XCTAssertEqual(TranscriptFormatter.timestamp(192.7), "00:03:12")
        XCTAssertEqual(TranscriptFormatter.timestamp(3725), "01:02:05")
    }

    func testMergeInterleavesAndJoinsSameSpeaker() {
        let segs = [
            Segment(start: 0, end: 2, speaker: "Me", text: "Ciao"),
            Segment(start: 2.5, end: 4, speaker: "Me", text: "come va?"),
            Segment(start: 5, end: 7, speaker: "Others", text: "Bene, grazie."),
            Segment(start: 1, end: 1.5, speaker: "Others", text: " "),
            Segment(start: 8, end: 9, speaker: "Me", text: "Ottimo."),
        ]
        let merged = TranscriptFormatter.merge(segs)
        XCTAssertEqual(merged.map(\.speaker), ["Me", "Others", "Me"])
        XCTAssertEqual(merged[0].text, "Ciao come va?")
        XCTAssertEqual(merged[0].end, 4)
        XCTAssertEqual(TranscriptFormatter.body(merged).components(separatedBy: "\n\n").first,
                       "**[00:00:00] Me:** Ciao come va?")
    }

    func testMarkdownHeader() {
        let md = TranscriptFormatter.markdown(
            header: .init(title: "Weekly", date: Date(timeIntervalSince1970: 0), durationSeconds: 65,
                          provider: "whisper.cpp", language: "auto (detected: it)", audioFiles: ["mic.m4a"]),
            merged: [Segment(start: 3, end: 4, speaker: "Me", text: "Hi")])
        XCTAssertTrue(md.hasPrefix("# Weekly\n"))
        XCTAssertTrue(md.contains("- **Duration:** 00:01:05"))
        XCTAssertTrue(md.contains("- **Language:** auto (detected: it)"))
        XCTAssertTrue(md.contains("**[00:00:03] Me:** Hi"))
    }

    func testWordGrouping() {
        let words = [
            TimedWord(text: "Hello", start: 0, end: 0.4, speaker: "speaker_0"),
            TimedWord(text: "there", start: 0.5, end: 0.9, speaker: "speaker_0"),
            TimedWord(text: ".", start: 0.9, end: 0.9, speaker: "speaker_0"),
            TimedWord(text: "Hi", start: 1.2, end: 1.5, speaker: "speaker_1"),
            TimedWord(text: "again", start: 5, end: 5.4, speaker: "speaker_1"),
        ]
        let segs = TranscriptFormatter.normalizeSpeakers(TranscriptFormatter.group(words: words))
        XCTAssertEqual(segs.map(\.text), ["Hello there.", "Hi", "again"])
        XCTAssertEqual(segs.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 2"])
    }

    func testSlugAndFolderName() {
        XCTAssertEqual(Naming.slug("Riunione Perché è Così!"), "riunione-perche-e-cosi")
        XCTAssertEqual(Naming.slug("  ///  "), "recording")
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 23; c.hour = 14; c.minute = 30
        let d = Calendar.current.date(from: c)!
        XCTAssertEqual(Naming.folderName(date: d, title: "Sync w/ Team"), "2026-09-23_1430_sync-w-team")
        XCTAssertEqual(Naming.defaultTitle(date: d), "Call 2026-09-23 14:30")
    }

    func testParsers() throws {
        let whisper = """
        {"result":{"language":"it"},"transcription":[{"timestamps":{"from":"00:00:00,000","to":"00:00:02,500"},
        "offsets":{"from":0,"to":2500},"text":" Ciao a tutti"}]}
        """
        let w = try ResponseParsers.whisperCpp(Data(whisper.utf8))
        XCTAssertEqual(w.detectedLanguage, "it")
        XCTAssertEqual(w.segments.first?.end, 2.5)

        let eleven = """
        {"language_code":"ita","text":"Ciao ciao","words":[
        {"text":"Ciao","start":0.1,"end":0.4,"type":"word","speaker_id":"speaker_0"},
        {"text":" ","start":0.4,"end":0.5,"type":"spacing","speaker_id":"speaker_0"},
        {"text":"ciao","start":0.5,"end":0.8,"type":"word","speaker_id":"speaker_0"}]}
        """
        let e = try ResponseParsers.elevenLabs(Data(eleven.utf8), diarized: true)
        XCTAssertEqual(e.segments.map(\.text), ["Ciao ciao"])
        XCTAssertEqual(e.detectedLanguage, "ita")

        let verbose = """
        {"language":"italian","duration":5,"text":"x","segments":[{"id":0,"start":1.0,"end":2.0,"text":" Buongiorno"}]}
        """
        let v = try ResponseParsers.openAI(Data(verbose.utf8), offset: 600, chunkDuration: 600)
        XCTAssertEqual(v.segments.first?.start, 601)

        let diarized = """
        {"text":"a b","segments":[{"type":"transcript.text.segment","id":"s0","speaker":"A","start":0.5,"end":1.0,"text":"a"}]}
        """
        let dz = try ResponseParsers.openAI(Data(diarized.utf8), offset: 0, chunkDuration: 60)
        XCTAssertEqual(dz.segments.first?.speaker, "A")

        let plain = try ResponseParsers.openAI(Data(#"{"text":"solo testo"}"#.utf8), offset: 60, chunkDuration: 60)
        XCTAssertEqual(plain.segments.first?.start, 60)
        XCTAssertEqual(plain.segments.first?.end, 120)
    }
}

final class TranscriptParseTests: XCTestCase {
    func testRoundTrip() {
        let merged = [
            Segment(start: 3, end: 5, speaker: "Me", text: "Ciao a tutti."),
            Segment(start: 3725, end: 3730, speaker: "Speaker 1", text: "Sì: ci siamo, **ok**."),
        ]
        let md = TranscriptFormatter.markdown(
            header: .init(title: "T", date: Date(), durationSeconds: 1, provider: "p", language: "it", audioFiles: []),
            merged: merged)
        let blocks = TranscriptFormatter.parseBlocks(md)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], TranscriptBlock(start: 3, speaker: "Me", text: "Ciao a tutti."))
        XCTAssertEqual(blocks[1].start, 3725)
        XCTAssertEqual(blocks[1].speaker, "Speaker 1")
        XCTAssertEqual(blocks[1].text, "Sì: ci siamo, **ok**.")
    }
}
