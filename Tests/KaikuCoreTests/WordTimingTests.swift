import XCTest
@testable import KaikuCore

final class WordTimingTests: XCTestCase {
    private typealias Word = Segment.Word

    func testSegmentsSavedWithoutWordsStillDecode() throws {
        let old = #"[{"start":1,"end":2.5,"speaker":"Me","text":"Ciao"},{"start":3,"end":4,"text":"Eco","droppedAsEcho":true}]"#
        let segs = try JSONDecoder().decode([Segment].self, from: Data(old.utf8))
        XCTAssertEqual(segs, [Segment(start: 1, end: 2.5, speaker: "Me", text: "Ciao"),
                              Segment(start: 3, end: 4, text: "Eco", droppedAsEcho: true)])
        XCTAssertNil(segs[0].words)
        // Segments without words are saved as before.
        let json = String(decoding: try JSONEncoder().encode(segs[0]), as: UTF8.self)
        XCTAssertFalse(json.contains("words"))

        let timed = Segment(start: 0, end: 1, text: "Hi", words: [Word(start: 0.1, end: 0.4, text: "Hi")])
        XCTAssertEqual(try JSONDecoder().decode(Segment.self, from: JSONEncoder().encode(timed)), timed)
    }

    func testWhisperCppTokensBecomeWords() throws {
        let json = """
        {"result":{"language":"it"},"transcription":[{"timestamps":{"from":"00:00:00,000","to":"00:00:02,500"},
        "offsets":{"from":0,"to":2500},"text":" Ciao a tutti, bene.","tokens":[
        {"text":"[_BEG_]","offsets":{"from":0,"to":0},"id":50365,"p":0.9,"t_dtw":-1},
        {"text":" Ciao","offsets":{"from":0,"to":400},"id":1,"p":0.9,"t_dtw":-1},
        {"text":" a","offsets":{"from":400,"to":600},"id":2,"p":0.9,"t_dtw":-1},
        {"text":" tut","offsets":{"from":600,"to":900},"id":3,"p":0.9,"t_dtw":-1},
        {"text":"ti","offsets":{"from":900,"to":1200},"id":4,"p":0.9,"t_dtw":-1},
        {"text":",","offsets":{"from":1200,"to":1250},"id":5,"p":0.9,"t_dtw":-1},
        {"text":" bene","offsets":{"from":1300,"to":1900},"id":6,"p":0.9,"t_dtw":-1},
        {"text":".","offsets":{"from":1900,"to":2000},"id":7,"p":0.9,"t_dtw":-1},
        {"text":"[_TT_125]","offsets":{"from":2500,"to":2500},"id":50490,"p":0.9,"t_dtw":-1}]},
        {"offsets":{"from":2500,"to":4000},"text":" Senza token"}]}
        """
        let r = try ResponseParsers.whisperCpp(Data(json.utf8))
        XCTAssertEqual(r.segments.count, 2)
        XCTAssertEqual(r.segments[0].words, [
            Word(start: 0, end: 0.4, text: "Ciao"), Word(start: 0.4, end: 0.6, text: "a"),
            Word(start: 0.6, end: 1.25, text: "tutti,"), Word(start: 1.3, end: 2, text: "bene."),
        ])
        XCTAssertNil(r.segments[1].words)
    }

    func testWhisperCppDTWTimesDriveWords() throws {
        let json = """
        {"transcription":[{"offsets":{"from":0,"to":30000},"text":" Thank you.","tokens":[
        {"text":"[_BEG_]","offsets":{"from":0,"to":0},"t_dtw":-1},
        {"text":" Thank","offsets":{"from":0,"to":16380},"t_dtw":970},
        {"text":" you","offsets":{"from":18970,"to":29720},"t_dtw":985},
        {"text":".","offsets":{"from":29720,"to":29900},"t_dtw":988},
        {"text":"[_TT_1500]","offsets":{"from":30000,"to":30000},"t_dtw":-1}]}]}
        """
        let r = try ResponseParsers.whisperCpp(Data(json.utf8))
        XCTAssertEqual(r.segments[0].words, [
            Word(start: 9.7, end: 9.85, text: "Thank"), Word(start: 9.85, end: 30, text: "you."),
        ])
    }

    func testWhisperCppDTWPreset() {
        let p = ResponseParsers.whisperCppDTWPreset
        XCTAssertEqual(p("ggml-large-v3-turbo.bin"), "large.v3.turbo")
        XCTAssertEqual(p("/m/ggml-large-v3-turbo-q5_0.bin"), "large.v3.turbo")
        XCTAssertEqual(p("ggml-large-v3.bin"), "large.v3")
        XCTAssertEqual(p("ggml-large-v2.bin"), "large.v2")
        XCTAssertEqual(p("ggml-medium.en.bin"), "medium.en")
        XCTAssertEqual(p("ggml-small-q8_0.bin"), "small")
        XCTAssertEqual(p("ggml-base.en-q5_1.bin"), "base.en")
        XCTAssertEqual(p("ggml-tiny.bin"), "tiny")
        XCTAssertNil(p("ggml-large-v3-custom.bin"))
        XCTAssertNil(p("my-model.bin"))
    }

    func testWhisperCppTokensWithoutTimesOrWithHalfCharacters() throws {
        let untimed = """
        {"transcription":[{"offsets":{"from":0,"to":1000},"text":" Ciao","tokens":[{"text":" Ciao","id":1}]}]}
        """
        XCTAssertNil(try ResponseParsers.whisperCpp(Data(untimed.utf8)).segments[0].words)

        // "é" split across two tokens: neither half is valid UTF-8 on its own.
        var data = Data(#"{"transcription":[{"offsets":{"from":0,"to":1000},"text":" caffé","tokens":["#.utf8)
        data += Data(#"{"text":" caff","offsets":{"from":0,"to":500}},{"text":""#.utf8)
        data += Data([0xC3])
        data += Data(#"","offsets":{"from":500,"to":600}},{"text":""#.utf8)
        data += Data([0xA9])
        data += Data(#"","offsets":{"from":600,"to":800}}]}]}"#.utf8)
        let r = try ResponseParsers.whisperCpp(data)
        XCTAssertEqual(r.segments[0].words, [Word(start: 0, end: 0.8, text: "caffé")])
    }

    func testOpenAIWordsGoToTheirSegments() throws {
        let json = """
        {"language":"italian","duration":5,"text":"Buongiorno a tutti. Iniziamo.","segments":[
        {"id":0,"start":0.0,"end":2.0,"text":" Buongiorno a tutti."},{"id":1,"start":2.0,"end":4.0,"text":" Iniziamo."}],
        "words":[{"word":"Buongiorno","start":0.0,"end":0.6},{"word":"a","start":0.6,"end":0.8},
        {"word":"tutti","start":0.8,"end":1.5},{"word":"Iniziamo","start":2.1,"end":3.0},{"word":"dopo","start":4.5,"end":4.8}]}
        """
        let r = try ResponseParsers.openAI(Data(json.utf8), offset: 600, chunkDuration: 600)
        XCTAssertEqual(r.segments[0].words?.map(\.text), ["Buongiorno", "a", "tutti"])
        XCTAssertEqual(r.segments[0].words?.first?.start, 600)
        // A word after the last segment goes to the nearest one.
        XCTAssertEqual(r.segments[1].words?.map(\.text), ["Iniziamo", "dopo"])
        XCTAssertEqual(r.segments[1].words?.first?.start ?? 0, 602.1, accuracy: 0.0001)

        let noWords = try ResponseParsers.openAI(Data(#"{"segments":[{"start":1,"end":2,"text":"x"}]}"#.utf8), offset: 0, chunkDuration: 60)
        XCTAssertNil(noWords.segments[0].words)
    }

    func testElevenLabsKeepsWords() throws {
        let json = """
        {"language_code":"ita","text":"Ciao, ciao","words":[
        {"text":"Ciao","start":0.1,"end":0.4,"type":"word","speaker_id":"speaker_0"},
        {"text":",","start":0.4,"end":0.4,"type":"word","speaker_id":"speaker_0"},
        {"text":" ","start":0.4,"end":0.5,"type":"spacing","speaker_id":"speaker_0"},
        {"text":"ciao","start":0.5,"end":0.8,"type":"word","speaker_id":"speaker_0"}]}
        """
        let r = try ResponseParsers.elevenLabs(Data(json.utf8), diarized: true)
        XCTAssertEqual(r.segments.map(\.text), ["Ciao, ciao"])
        XCTAssertEqual(r.segments[0].words?.map(\.text), ["Ciao", ",", "ciao"])
    }

    func testRemapMovesWords() {
        let map = TimeMap(keep: [TimeRange(start: 3, end: 5.5), TimeRange(start: 9.5, end: 17.5)])
        let seg = Segment(start: 1, end: 4, text: "a b", words: [Word(start: 1, end: 2, text: "a"), Word(start: 2.6, end: 3, text: "b")])
        let words = map.remap([seg])[0].words ?? []
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].start, 4)
        XCTAssertEqual(words[0].end, 5, accuracy: 0.01)
        XCTAssertEqual(words[1].start, 9.6, accuracy: 0.0001)
        XCTAssertEqual(words[1].end, 10, accuracy: 0.01)
        XCTAssertNil(map.remap([Segment(start: 1, end: 2, text: "x")])[0].words)
    }

    func testMergeJoinsWords() {
        let merged = TranscriptFormatter.merge([
            Segment(start: 0, end: 1, speaker: "Me", text: "Ciao", words: [Word(start: 0, end: 1, text: "Ciao")]),
            Segment(start: 1.5, end: 2, speaker: "Me", text: "come va?",
                    words: [Word(start: 1.5, end: 1.7, text: "come"), Word(start: 1.7, end: 2, text: "va?")]),
            Segment(start: 3, end: 4, speaker: "Others", text: "Bene."),
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].words?.map(\.text), ["Ciao", "come", "va?"])
        XCTAssertNil(merged[1].words)
    }
}
