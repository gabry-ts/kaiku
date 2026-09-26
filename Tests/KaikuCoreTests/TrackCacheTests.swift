import XCTest
@testable import KaikuCore

final class TrackCacheTests: XCTestCase {
    private let key = TrackCache.Key(provider: "OpenAI (gpt-4o-mini-transcribe)", language: nil, trim: .init(),
                                     audioBytes: 123_456, audioModified: 1_790_000_000.123456)

    private func saved(_ key: TrackCache.Key) throws -> Data {
        try JSONEncoder().encode(TrackCache(key: key, segments: [Segment(start: 1, end: 2, text: "hi")],
                                            detectedLanguage: "en", seconds: 42))
    }

    func testSameSettingsReuse() throws {
        let cache = TrackCache.reusable(try saved(key), for: key)
        XCTAssertEqual(cache?.segments, [Segment(start: 1, end: 2, text: "hi")])
        XCTAssertEqual(cache?.detectedLanguage, "en")
        XCTAssertEqual(cache?.seconds, 42)
    }

    func testAnyChangePreventsReuse() throws {
        let data = try saved(key)
        var k = key; k.provider = "OpenAI (whisper-1)"
        XCTAssertNil(TrackCache.reusable(data, for: k))
        k = key; k.language = "it"
        XCTAssertNil(TrackCache.reusable(data, for: k))
        k = TrackCache.Key(provider: key.provider, language: nil, trim: nil, audioBytes: key.audioBytes, audioModified: key.audioModified)
        XCTAssertNil(TrackCache.reusable(data, for: k))
        k = TrackCache.Key(provider: key.provider, language: nil, trim: .init(thresholdDB: -50), audioBytes: key.audioBytes, audioModified: key.audioModified)
        XCTAssertNil(TrackCache.reusable(data, for: k))
        k = key; k.audioBytes += 1
        XCTAssertNil(TrackCache.reusable(data, for: k))
        k = key; k.audioModified += 1
        XCTAssertNil(TrackCache.reusable(data, for: k))
    }

    func testMissingOrBrokenFile() {
        XCTAssertNil(TrackCache.reusable(nil, for: key))
        XCTAssertNil(TrackCache.reusable(Data("not json".utf8), for: key))
    }
}
