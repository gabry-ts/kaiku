import XCTest
@testable import KaikuCore

final class LoudnessMatchTests: XCTestCase {
    private let rate = 16_000.0

    /// Sine bursts of `amplitude` separated by silence, `seconds` in total.
    private func track(amplitude: Float, seconds: Int = 20) -> [Float] {
        (0..<(seconds * Int(rate))).map { i in
            let t = Double(i) / rate
            return Int(t) % 4 < 2 ? amplitude * Float(sin(2 * Double.pi * 440 * t)) : 0
        }
    }

    private func meter(_ samples: [Float]) -> LoudnessMeter {
        var m = LoudnessMeter(sampleRate: rate)
        samples.withUnsafeBufferPointer { m.add(channels: [$0.baseAddress!], count: $0.count) }
        return m
    }

    func testSilencesAreIgnored() throws {
        // A sine of amplitude 0.1 is -23 dBFS; burst-edge windows pull the estimate slightly lower.
        let l = try XCTUnwrap(meter(track(amplitude: 0.1)).loudness)
        XCTAssertEqual(l, -23.0, accuracy: 1.0)
    }

    func testGainsEqualizeLoudAndQuiet() throws {
        let loud = try XCTUnwrap(meter(track(amplitude: 0.5)).loudness)
        let quiet = try XCTUnwrap(meter(track(amplitude: 0.02)).loudness)
        let gl = Double(LoudnessMatch.gain(forLoudness: loud))
        let gq = Double(LoudnessMatch.gain(forLoudness: quiet))
        let after = { (l: Double, g: Double) in l + 20 * log10(g) }
        XCTAssertEqual(after(loud, gl), after(quiet, gq), accuracy: 0.01)
        XCTAssertEqual(after(loud, gl), LoudnessMatch.targetDb, accuracy: 0.01)
    }

    func testSilentTrackHasNoLoudnessAndUnitGain() {
        let m = meter([Float](repeating: 0, count: 5 * Int(rate)))
        XCTAssertNil(m.loudness)
        XCTAssertEqual(LoudnessMatch.gain(forLoudness: m.loudness), 1)
        XCTAssertNil(meter(track(amplitude: 0.0001)).loudness)
    }

    func testGainIsCapped() {
        XCTAssertEqual(Double(LoudnessMatch.gain(forLoudness: -60)), pow(10, 18.0 / 20), accuracy: 1e-4)
        XCTAssertEqual(Double(LoudnessMatch.gain(forLoudness: 0)), pow(10, -18.0 / 20), accuracy: 1e-4)
    }

    func testLimiterScale() {
        XCTAssertEqual(LoudnessMatch.limiterScale(peak: 0.5), 1)
        let scale = LoudnessMatch.limiterScale(peak: 2)
        XCTAssertEqual(2 * scale, Float(pow(10, -1.0 / 20)), accuracy: 1e-5)
    }
}
