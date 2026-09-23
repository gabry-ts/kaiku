import Foundation

public struct TimeRange: Equatable, Sendable, Codable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
    public var duration: Double { max(0, end - start) }
}

/// Silence detection and the mapping between a trimmed file and the original timeline.
public enum SilenceTrimmer {
    public struct Options: Equatable, Sendable {
        /// Below this peak level a window counts as silent.
        public var thresholdDB: Double
        /// Only silences at least this long are cut.
        public var minDuration: Double
        /// Audio kept on each side of a cut, so words at the edges are not clipped.
        public var padding: Double

        public init(thresholdDB: Double = -45, minDuration: Double = 2, padding: Double = 0.4) {
            self.thresholdDB = thresholdDB
            self.minDuration = minDuration
            self.padding = padding
        }
    }

    /// Converts a linear peak (0...1) to dBFS.
    public static func decibels(_ peak: Float) -> Double {
        peak > 0 ? 20 * log10(Double(peak)) : -200
    }

    /// Silent stretches from per-window peak levels (linear 0...1) of `window` seconds each.
    public static func silences(peaks: [Float], window: Double, options: Options) -> [TimeRange] {
        var out: [TimeRange] = []
        var runStart: Int?
        func close(_ end: Int) {
            if let s = runStart, Double(end - s) * window >= options.minDuration {
                out.append(TimeRange(start: Double(s) * window, end: Double(end) * window))
            }
            runStart = nil
        }
        for (i, p) in peaks.enumerated() {
            if decibels(p) < options.thresholdDB {
                if runStart == nil { runStart = i }
            } else {
                close(i)
            }
        }
        close(peaks.count)
        return out
    }

    /// Ranges of the original audio to keep, given the silences to cut.
    public static func keepRanges(duration: Double, silences: [TimeRange], padding: Double) -> [TimeRange] {
        var keep: [TimeRange] = []
        var cursor = 0.0
        for s in silences.sorted(by: { $0.start < $1.start }) {
            // Leading/trailing silence needs padding on one side only.
            let cutStart = s.start <= 0 ? 0 : s.start + padding
            let cutEnd = s.end >= duration ? duration : s.end - padding
            guard cutEnd > cutStart else { continue }
            if cutStart > cursor { keep.append(TimeRange(start: cursor, end: cutStart)) }
            cursor = max(cursor, cutEnd)
        }
        if cursor < duration { keep.append(TimeRange(start: cursor, end: duration)) }
        return keep
    }
}

/// Maps times in a file made by concatenating `keep` ranges back to the original timeline.
public struct TimeMap: Equatable, Sendable {
    public let keep: [TimeRange]

    public init(keep: [TimeRange]) { self.keep = keep }

    public var trimmedDuration: Double { keep.reduce(0) { $0 + $1.duration } }

    public func toOriginal(_ t: Double) -> Double {
        guard !keep.isEmpty else { return t }
        var offset = 0.0
        for r in keep {
            if t < offset + r.duration { return r.start + max(0, t - offset) }
            offset += r.duration
        }
        // Past the end: extend from the last range.
        let last = keep[keep.count - 1]
        return last.end + (t - offset)
    }

    public func remap(_ segments: [Segment]) -> [Segment] {
        segments.map { s in
            var c = s
            c.start = toOriginal(s.start)
            // Map the end as the end of the previous instant, so a segment ending exactly
            // at a cut does not jump over the removed silence.
            c.end = max(c.start, toOriginal(max(s.start, s.end - 0.001)) + 0.001)
            return c
        }
    }
}
