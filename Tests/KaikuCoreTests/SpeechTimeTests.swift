import XCTest
@testable import KaikuCore

final class SpeechTimeTests: XCTestCase {
    private func r(_ start: Double, _ end: Double) -> TimeRange { TimeRange(start: start, end: end) }

    func testTracksAddUpWhenApart() {
        // You talk for 20 s, then the other side for 20 s.
        XCTAssertEqual(SpeechTime.total([[r(0, 20)], [r(30, 50)]]), 40)
    }

    func testOverlapsCountOnce() {
        XCTAssertEqual(SpeechTime.total([[r(0, 20)], [r(10, 30)]]), 30)
        XCTAssertEqual(SpeechTime.total([[r(0, 10), r(20, 30)], [r(5, 25)]]), 30)
    }

    func testEmpty() {
        XCTAssertEqual(SpeechTime.total([]), 0)
        XCTAssertEqual(SpeechTime.total([[], []]), 0)
    }

    func testSoundRangesSkipLongSilences() {
        // 0.5 s windows: 2 s loud, 3 s silent, 1 s loud.
        let loud: Float = 0.5, quiet: Float = 0.0001
        let peaks = [Float](repeating: loud, count: 4) + [Float](repeating: quiet, count: 6) + [Float](repeating: loud, count: 2)
        let ranges = SpeechTime.soundRanges(peaks: peaks, window: 0.5, duration: 6,
                                            options: SilenceTrimmer.Options(thresholdDB: -45, minDuration: 2))
        XCTAssertEqual(ranges, [r(0, 2), r(5, 6)])
        XCTAssertEqual(SpeechTime.total([ranges]), 3)
    }
}
