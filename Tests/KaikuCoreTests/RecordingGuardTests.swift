import XCTest
@testable import KaikuCore

final class RecordingGuardTests: XCTestCase {
    func testStopsAfterSilence() {
        var g = RecordingGuard(silenceLimit: 60)
        XCTAssertNil(g.update(recorded: 10, micLevel: 0.2, systemLevel: 0))
        XCTAssertNil(g.update(recorded: 69, micLevel: 0, systemLevel: 0.001))
        XCTAssertEqual(g.update(recorded: 70, micLevel: 0, systemLevel: 0), .silence)
    }

    func testSoundOnEitherTrackResetsTheSilence() {
        var g = RecordingGuard(silenceLimit: 60)
        XCTAssertNil(g.update(recorded: 50, micLevel: 0, systemLevel: 0.3))
        XCTAssertNil(g.update(recorded: 100, micLevel: 0, systemLevel: 0))
        XCTAssertNil(g.update(recorded: 105, micLevel: 0.1, systemLevel: 0))
        XCTAssertNil(g.update(recorded: 164, micLevel: 0, systemLevel: 0))
        XCTAssertEqual(g.update(recorded: 165, micLevel: 0, systemLevel: 0), .silence)
    }

    func testStopsAtMaximumLength() {
        var g = RecordingGuard(silenceLimit: 0, maxDuration: 3600)
        XCTAssertNil(g.update(recorded: 3599, micLevel: 0.5, systemLevel: 0.5))
        XCTAssertEqual(g.update(recorded: 3600, micLevel: 0.5, systemLevel: 0.5), .maxDuration)
    }

    func testZeroDisablesBothLimits() {
        var g = RecordingGuard()
        XCTAssertNil(g.update(recorded: 100_000, micLevel: 0, systemLevel: 0))
    }

    func testDescribe() {
        XCTAssertEqual(RecordingGuard.describe(seconds: 60), "1 minute")
        XCTAssertEqual(RecordingGuard.describe(seconds: 900), "15 minutes")
        XCTAssertEqual(RecordingGuard.describe(seconds: 3600), "1 hour")
        XCTAssertEqual(RecordingGuard.describe(seconds: 14400), "4 hours")
    }
}
