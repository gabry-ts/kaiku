import Foundation

/// Where the call audio was playing during part of a recording, in recorded seconds.
public struct OutputRoute: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double?
    public var deviceName: String
    /// False for loudspeakers (built-in speakers, HDMI, AirPlay), whose sound reaches the mic.
    public var isHeadphones: Bool

    public init(start: Double, end: Double? = nil, deviceName: String, isHeadphones: Bool) {
        self.start = start
        self.end = end
        self.deviceName = deviceName
        self.isHeadphones = isHeadphones
    }

    func contains(_ t: Double) -> Bool { t >= start && t < (end ?? .infinity) }
}

/// Finds microphone segments that are only the other people's voices picked up from the
/// speakers (the same words, at the same time, as a call audio segment).
public enum EchoFilter {
    public struct Options: Equatable, Sendable {
        /// Maximum start difference between the two segments, when they don't overlap.
        public var maxStartDelta: Double = 3
        /// Share of the mic words (and word pairs) that must appear in the call audio text.
        public var minSimilarity: Double = 0.8
        /// Segments shorter than this many words must match exactly.
        public var shortWords: Int = 3
        public init() {}
    }

    /// Returns the segments with `droppedAsEcho = true` on echoed microphone segments.
    /// Only mic segments inside speaker (non-headphone) routes are checked; others are never dropped.
    public static func markEchoes(_ segments: [Segment], meLabel: String, routes: [OutputRoute],
                                  options: Options = Options()) -> [Segment] {
        let speakerRoutes = routes.filter { !$0.isHeadphones }
        guard !speakerRoutes.isEmpty else { return segments }
        let others = segments.filter { $0.speaker != meLabel }
        return segments.map { seg in
            guard seg.speaker == meLabel, seg.droppedAsEcho != true else { return seg }
            let mid = (seg.start + seg.end) / 2
            guard speakerRoutes.contains(where: { $0.contains(seg.start) || $0.contains(mid) }) else { return seg }
            var c = seg
            if isEcho(seg, of: others, options: options) { c.droppedAsEcho = true }
            return c
        }
    }

    static func isEcho(_ me: Segment, of others: [Segment], options: Options) -> Bool {
        let meWords = words(me.text)
        guard !meWords.isEmpty else { return false }
        let near = others.filter { o in
            let overlaps = o.start < me.end + 1 && me.start < o.end + 1
            return overlaps || abs(o.start - me.start) <= options.maxStartDelta
        }
        guard !near.isEmpty else { return false }

        if meWords.count < options.shortWords {
            // Short replies ("yes", "ok thanks") only count as echo on an exact, close match.
            return near.contains { words($0.text) == meWords && abs($0.start - me.start) <= 1.5 }
        }
        // Compare with the call audio text around it (it may be split differently).
        let otherWords = near.sorted { $0.start < $1.start }.flatMap { words($0.text) }
        let wordSet = Set(otherWords)
        let wordShare = Double(meWords.filter { wordSet.contains($0) }.count) / Double(meWords.count)
        let pairs = bigrams(meWords)
        let otherPairs = Set(bigrams(otherWords))
        let pairShare = pairs.isEmpty ? wordShare : Double(pairs.filter { otherPairs.contains($0) }.count) / Double(pairs.count)
        return wordShare >= options.minSimilarity && pairShare >= options.minSimilarity - 0.1
    }

    /// Lowercased words without punctuation or accents.
    public static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func bigrams(_ w: [String]) -> [String] {
        w.count < 2 ? [] : (0..<(w.count - 1)).map { w[$0] + " " + w[$0 + 1] }
    }
}
