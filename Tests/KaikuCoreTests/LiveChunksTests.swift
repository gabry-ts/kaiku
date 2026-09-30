import XCTest
@testable import KaikuCore

final class LiveChunksTests: XCTestCase {
    typealias Chunk = ChunkPlanner.Chunk

    func testChunksOverlapThePreviousOne() {
        var p = ChunkPlanner(sampleRate: 100, seconds: 10, overlap: 2, maxPending: 5)
        p.add(999)
        XCTAssertTrue(p.pending.isEmpty)
        p.add(1)
        XCTAssertEqual(p.pending, [Chunk(start: 0, fresh: 0, end: 1000)])
        p.add(1500)
        XCTAssertEqual(p.pending.last, Chunk(start: 800, fresh: 1000, end: 2000))
        XCTAssertEqual(p.take(), Chunk(start: 0, fresh: 0, end: 1000))
        XCTAssertEqual(p.take(), Chunk(start: 800, fresh: 1000, end: 2000))
        XCTAssertNil(p.take())
    }

    func testOneLongBufferGivesSeveralChunks() {
        var p = ChunkPlanner(sampleRate: 100, seconds: 10, overlap: 2, maxPending: 5)
        p.add(3100)
        XCTAssertEqual(p.pending.map(\.fresh), [0, 1000, 2000])
        XCTAssertEqual(p.pending.map(\.end), [1000, 2000, 3000])
    }

    func testOldestChunkIsDroppedWhenBehind() {
        var p = ChunkPlanner(sampleRate: 100, seconds: 10, overlap: 2, maxPending: 2)
        p.add(3000)
        XCTAssertEqual(p.pending.map(\.fresh), [1000, 2000])
        XCTAssertEqual(p.dropped, 1)
        p.add(1000)
        XCTAssertEqual(p.pending.map(\.fresh), [2000, 3000])
        XCTAssertEqual(p.dropped, 2)
    }

    func testFinishKeepsTheRestUnlessTooShort() {
        var p = ChunkPlanner(sampleRate: 100, seconds: 10, overlap: 2)
        p.add(1050)
        _ = p.take()
        p.finish(minimum: 100)
        XCTAssertNil(p.take())
        p.add(200)
        p.finish(minimum: 100)
        XCTAssertEqual(p.take(), Chunk(start: 800, fresh: 1000, end: 1250))
        p.finish(minimum: 100)
        XCTAssertNil(p.take())
    }

    func testKeepFromCoversPendingChunksAndTheNextOverlap() {
        var p = ChunkPlanner(sampleRate: 100, seconds: 10, overlap: 2, maxPending: 3)
        XCTAssertEqual(p.keepFrom, 0)
        p.add(2000)
        XCTAssertEqual(p.keepFrom, 0)
        _ = p.take()
        XCTAssertEqual(p.keepFrom, 800)
        _ = p.take()
        XCTAssertEqual(p.keepFrom, 1800)
    }

    func testOverlappedWordsAreKeptOnce() {
        XCTAssertEqual(OverlapText.trim("ship it on Friday. Then we test", after: "So we will ship it on Friday"),
                       "Then we test")
        XCTAssertEqual(OverlapText.trim("On friday, then we test", after: "ship it on Friday."), "then we test")
        XCTAssertEqual(OverlapText.trim("Nothing in common", after: "ship it on Friday"), "Nothing in common")
        XCTAssertEqual(OverlapText.trim("Hello there", after: ""), "Hello there")
        XCTAssertEqual(OverlapText.trim("ship it on Friday", after: "ship it on Friday"), "")
    }

    func testWordsCutAtTheEdgeStillMatch() {
        XCTAssertEqual(OverlapText.trim("ship it on Friday and then", after: "we ship it on Fri"), "and then")
        XCTAssertEqual(OverlapText.trim("day we ship it again", after: "on Friday we ship it"), "again")
    }

    func testSoundNotesAreRemoved() {
        XCTAssertEqual(OverlapText.spoken(" [BLANK_AUDIO] "), "")
        XCTAssertEqual(OverlapText.spoken("Hello (music)  there [laughs]"), "Hello there")
    }

    func testSilenceIsToldFromSpeech() {
        XCTAssertTrue(ChunkAudio.isSilent([], sampleRate: 16_000))
        XCTAssertTrue(ChunkAudio.isSilent([Int16](repeating: 20, count: 32_000), sampleRate: 16_000))
        // A short loud burst in a quiet chunk still counts as speech.
        var samples = [Int16](repeating: 0, count: 160_000)
        for i in 80_000..<83_200 { samples[i] = i % 2 == 0 ? 6000 : -6000 }
        XCTAssertFalse(ChunkAudio.isSilent(samples, sampleRate: 16_000))
    }

    func testWavHeader() {
        let data = ChunkAudio.wav([1, -1, 256], sampleRate: 16_000)
        XCTAssertEqual(data.count, 50)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(Array(data[24..<28]), [0x80, 0x3E, 0, 0])
        XCTAssertEqual(Array(data[40..<44]), [6, 0, 0, 0])
        XCTAssertEqual(Array(data[44...]), [1, 0, 0xFF, 0xFF, 0, 1])
    }
}
