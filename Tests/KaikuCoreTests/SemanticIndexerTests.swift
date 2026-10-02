import XCTest
@testable import KaikuCore

final class SemanticIndexerTests: XCTestCase {
    /// Counts vowels, so similar words give similar vectors; knows only the languages it is given.
    private struct FakeEmbedder: TextEmbedder {
        var languages: Set<String> = ["en", "it"]
        func supports(language: String) -> Bool { languages.contains(language) }
        func embed(_ text: String, language: String) -> [Float]? {
            guard supports(language: language) else { return nil }
            return ["a", "e", "o", "u"].map { l in Float(text.lowercased().filter { String($0) == l }.count) }
        }
    }

    private var folder: RecordingFolder!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kaiku-semantic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = RecordingFolder(url: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.url)
    }

    private func meta(language: String = "auto", detected: String? = nil) -> RecordingMeta {
        RecordingMeta(title: "Call", date: Date(), durationSeconds: 60, language: language, detectedLanguage: detected, status: .done)
    }

    private func saveSegments(_ texts: [String]) throws {
        try folder.saveSegments(texts.enumerated().map {
            Segment(start: Double($0.offset * 10), end: Double($0.offset * 10 + 5), speaker: "Me", text: $0.element)
        })
    }

    func testLanguagePrefersTheCallThenDetectedThenTextThenEnglish() {
        let e = FakeEmbedder()
        XCTAssertEqual(SemanticIndexer.language(for: meta(language: "it-IT"), sample: "x", embedder: e), "it")
        XCTAssertEqual(SemanticIndexer.language(for: meta(detected: "en"), sample: "x", embedder: e), "en")
        XCTAssertEqual(SemanticIndexer.language(for: meta(language: "de"), sample: "x", embedder: e), "en")
        XCTAssertEqual(SemanticIndexer.language(for: meta(), sample: "Questa è una frase in italiano, abbastanza lunga da riconoscere.", embedder: e), "it")
        XCTAssertNil(SemanticIndexer.language(for: meta(), sample: "x", embedder: FakeEmbedder(languages: [])))
    }

    func testBuildSavesAnIndexThatStaysFreshUntilTheTranscriptChanges() throws {
        let e = FakeEmbedder()
        let m = meta(language: "en")
        try saveSegments(["We agreed on the budget. It is approved."])
        XCTAssertTrue(SemanticIndexer.needsIndexing(folder, meta: m, embedder: e))
        let index = try XCTUnwrap(SemanticIndexer.build(folder, meta: m, embedder: e))
        XCTAssertEqual(index.language, "en")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(folder.loadSemanticIndex(), index)
        XCTAssertFalse(SemanticIndexer.needsIndexing(folder, meta: m, embedder: e))

        try saveSegments(["We agreed on the budget. It is rejected."])
        XCTAssertTrue(SemanticIndexer.needsIndexing(folder, meta: m, embedder: e))
        XCTAssertTrue(SemanticIndexer.needsIndexing(folder, meta: meta(language: "it"), embedder: e))
    }

    func testNothingToIndexWithoutSegmentsOrModel() throws {
        XCTAssertFalse(SemanticIndexer.needsIndexing(folder, meta: meta(), embedder: FakeEmbedder()))
        XCTAssertNil(SemanticIndexer.build(folder, meta: meta(), embedder: FakeEmbedder()))
        try saveSegments(["Hello there."])
        XCTAssertNil(SemanticIndexer.build(folder, meta: meta(), embedder: FakeEmbedder(languages: [])))
        XCTAssertNil(folder.loadSemanticIndex())
    }
}
