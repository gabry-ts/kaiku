import XCTest
@testable import KaikuCore

final class SemanticIndexTests: XCTestCase {
    func testChunksGroupThreeSentencesAndKeepTheStartTime() {
        let turn = Segment(start: 10, end: 50, speaker: "Anna", text: "One. Two. Three. Four. Five.")
        let passages = PassageChunker.chunks(from: [turn])
        XCTAssertEqual(passages.map(\.text), ["One. Two. Three.", "Four. Five."])
        XCTAssertEqual(passages[0].start, 10, accuracy: 0.001)
        XCTAssertEqual(passages[0].speaker, "Anna")
        XCTAssertGreaterThan(passages[1].start, 10)
        XCTAssertLessThan(passages[1].start, 50)
    }

    func testShortTurnsAreJoinedAndLongTextIsSplit() {
        let turns = [Segment(start: 0, end: 2, speaker: "A", text: "Hello there."),
                     Segment(start: 2, end: 4, speaker: "B", text: "Hi.")]
        let joined = PassageChunker.chunks(from: turns)
        XCTAssertEqual(joined.map(\.text), ["Hello there. Hi."])
        XCTAssertEqual(joined[0].speaker, "A")

        let long = Segment(start: 0, end: 60, text: Array(repeating: "This sentence has some words in it.", count: 30).joined(separator: " "))
        let split = PassageChunker.chunks(from: [long], maxSentences: 100, maxCharacters: 100)
        XCTAssertGreaterThan(split.count, 5)
        XCTAssertTrue(split.allSatisfy { $0.text.count < 160 })
        XCTAssertEqual(split.map(\.start), split.map(\.start).sorted())
    }

    func testEmptyTranscriptHasNoPassages() {
        XCTAssertTrue(PassageChunker.chunks(from: []).isEmpty)
        XCTAssertTrue(PassageChunker.chunks(from: [Segment(start: 0, end: 1, text: "  ")]).isEmpty)
    }

    func testCosine() {
        XCTAssertEqual(SemanticRanker.cosine([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(SemanticRanker.cosine([1, 0], [0, 1]), 0, accuracy: 0.0001)
        XCTAssertEqual(SemanticRanker.cosine([1, 1], [-1, -1]), -1, accuracy: 0.0001)
        XCTAssertEqual(SemanticRanker.cosine([0, 0], [1, 1]), 0)
        XCTAssertEqual(SemanticRanker.cosine([1], [1, 1]), 0)
        XCTAssertEqual(SemanticRanker.cosine([], []), 0)
    }

    private func index(_ language: String, _ vectors: [[Float]]) -> SemanticIndex {
        SemanticIndex(language: language, fingerprint: "f",
                      entries: vectors.enumerated().map { .init(passage: Passage(start: Double($0.offset), text: "p\($0.offset)"), vector: $0.element) })
    }

    func testRankingOrdersFiltersAndLimits() {
        let a = index("en", [[1, 0], [0.8, 0.6], [0, 1]])
        let b = index("en", [[0.9, 0.1]])
        let matches = SemanticRanker.rank(queries: ["en": [1, 0]], indexes: [("a", a), ("b", b)])
        XCTAssertEqual(matches.map(\.callID), ["a", "b", "a"])
        XCTAssertEqual(matches.map(\.passage.text), ["p0", "p0", "p1"])
        XCTAssertEqual(SemanticRanker.rank(queries: ["en": [1, 0]], indexes: [("a", a), ("b", b)], limit: 1).count, 1)
    }

    func testRankingSkipsIndexesOfOtherLanguages() {
        let it = index("it", [[1, 0]])
        XCTAssertTrue(SemanticRanker.rank(queries: ["en": [1, 0]], indexes: [("a", it)]).isEmpty)
        XCTAssertEqual(SemanticRanker.rank(queries: ["en": [1, 0], "it": [1, 0]], indexes: [("a", it)]).count, 1)
    }

    func testStaleness() {
        let passages = [Passage(start: 1, text: "Hello.")]
        let fp = SemanticIndex.fingerprint(of: passages)
        let fresh = SemanticIndex(language: "en", fingerprint: fp, entries: [])
        XCTAssertFalse(fresh.isStale(language: "en", fingerprint: fp))
        XCTAssertTrue(fresh.isStale(language: "it", fingerprint: fp))
        XCTAssertTrue(fresh.isStale(language: "en", fingerprint: SemanticIndex.fingerprint(of: [Passage(start: 1, text: "Hello!")])))
        XCTAssertTrue(SemanticIndex(version: 0, language: "en", fingerprint: fp, entries: []).isStale(language: "en", fingerprint: fp))
    }

    func testIndexRoundTripsThroughJSON() throws {
        let original = index("en", [[0.5, 0.25]])
        let decoded = try JSONDecoder().decode(SemanticIndex.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
