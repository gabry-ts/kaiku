import Foundation

/// A finished result of the system speech recognizer, as plain values.
public struct RecognizedSpeech: Equatable, Sendable {
    /// A run of the result's text, with its place in the audio when the recognizer gave one.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var start: Double?
        public var end: Double?

        public init(_ text: String, start: Double? = nil, end: Double? = nil) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// The audio the result covers, in seconds.
    public var start: Double
    public var end: Double
    public var runs: [Run]

    public init(start: Double, end: Double, runs: [Run]) {
        self.start = start
        self.end = end
        self.runs = runs
    }
}

/// Turns the recognizer's results into transcript segments, one per sentence.
public enum SpeechSegments {
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    public static func segments(from results: [RecognizedSpeech]) -> [Segment] {
        var out: [Segment] = []
        for result in results {
            // The text of each sentence, with the times of its first and last timed run.
            var sentences: [(text: String, start: Double?, end: Double?)] = []
            var open = false
            for run in result.runs {
                if !open { sentences.append(("", nil, nil)) }
                let i = sentences.count - 1
                sentences[i].text += run.text
                if let start = finite(run.start), let end = finite(run.end), end >= start {
                    if sentences[i].start == nil { sentences[i].start = start }
                    sentences[i].end = max(sentences[i].end ?? end, end)
                }
                let last = run.text.trimmingCharacters(in: .whitespacesAndNewlines).last
                open = !(last.map(sentenceEnds.contains) ?? false)
            }
            sentences = sentences
                .map { ($0.text.trimmingCharacters(in: .whitespacesAndNewlines), $0.start, $0.end) }
                .filter { !$0.text.isEmpty }

            // A sentence without times starts where the one before ends; only the last
            // one's end is known, from the result itself.
            var cursor = finite(result.start) ?? out.last?.end ?? 0
            for (index, sentence) in sentences.enumerated() {
                let start = sentence.start ?? cursor
                let known = sentence.end ?? (index == sentences.count - 1 ? finite(result.end) : nil)
                let end = max(start, known ?? start)
                out.append(Segment(start: start, end: end, text: sentence.text))
                cursor = end
            }
        }
        return out
    }

    private static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}
