import Foundation

/// Measures the loudness of the voiced parts of a track from a stream of samples.
/// Memory is one value per 100 ms, so hour-long tracks stay tiny.
public struct LoudnessMeter {
    public static let windowSeconds = 0.4
    public static let hopSeconds = 0.1
    /// Windows quieter than this are treated as silence.
    public static let absoluteGate = -50.0
    /// Windows this far under the mean of the remaining ones are dropped.
    public static let relativeGate = 10.0

    private let hopFrames: Int
    private var hopSum = 0.0
    private var hopCount = 0
    private var hops: [Double] = []

    public init(sampleRate: Double) {
        hopFrames = max(1, Int(sampleRate * Self.hopSeconds))
    }

    /// Adds `count` frames; `channels` holds one pointer per channel (energy is averaged over channels).
    public mutating func add(channels: [UnsafePointer<Float>], count: Int) {
        guard !channels.isEmpty else { return }
        for i in 0..<count {
            var e = 0.0
            for c in channels { let v = Double(c[i]); e += v * v }
            hopSum += e / Double(channels.count)
            hopCount += 1
            if hopCount == hopFrames {
                hops.append(hopSum / Double(hopFrames))
                hopSum = 0
                hopCount = 0
            }
        }
    }

    /// Mean-square energy of each 400 ms window (100 ms hop).
    var windowEnergies: [Double] {
        let n = Int((Self.windowSeconds / Self.hopSeconds).rounded())
        guard hops.count >= n else { return [] }
        return (0...(hops.count - n)).map { k in hops[k..<(k + n)].reduce(0, +) / Double(n) }
    }

    /// Loudness in dBFS of the voiced windows, or nil when there are none.
    public var loudness: Double? {
        func db(_ e: Double) -> Double { 10 * log10(e) }
        let voiced = windowEnergies.filter { $0 > 0 && db($0) > Self.absoluteGate }
        guard !voiced.isEmpty else { return nil }
        let meanDb = db(voiced.reduce(0, +) / Double(voiced.count))
        let kept = voiced.filter { db($0) >= meanDb - Self.relativeGate }
        guard !kept.isEmpty else { return nil }
        return db(kept.reduce(0, +) / Double(kept.count))
    }
}

/// Gain and limiter decisions for the listening mix.
public enum LoudnessMatch {
    public static let targetDb = -20.0
    public static let maxGainDb = 18.0
    public static let ceilingDb = -1.0

    /// Linear gain taking a track to the target loudness, capped; 1 when the track has no voiced audio.
    public static func gain(forLoudness loudness: Double?) -> Float {
        guard let loudness else { return 1 }
        let db = min(max(targetDb - loudness, -maxGainDb), maxGainDb)
        return Float(pow(10, db / 20))
    }

    /// Factor (at most 1) that brings a mix with the given absolute peak under the ceiling.
    public static func limiterScale(peak: Float) -> Float {
        let ceiling = Float(pow(10, ceilingDb / 20))
        return peak > ceiling ? ceiling / peak : 1
    }
}
