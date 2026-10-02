import Foundation

/// A timed part of a transcript line, highlighted while the audio plays.
public struct PlaybackSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// Character offsets in the line's text.
    public var range: Range<Int>
    /// False for a whole phrase, when the provider gave no word times.
    public var isWord: Bool

    public init(start: Double, end: Double, range: Range<Int>, isWord: Bool) {
        self.start = start
        self.end = end
        self.range = range
        self.isWord = isWord
    }
}

/// A speaker turn as shown in the library, with what to highlight while the audio plays.
public struct PlaybackLine: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    /// Sorted by start time.
    public var spans: [PlaybackSpan]

    public init(start: Double, end: Double, speaker: String, text: String, spans: [PlaybackSpan]) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.spans = spans
    }

    /// Where to play from for a double-click on character `offset`: the span under it,
    /// else the closest one before it, else the start of the line.
    public func seekTime(atCharacter offset: Int) -> Double {
        if let span = spans.first(where: { $0.range.contains(offset) }) { return span.start }
        let before = spans.filter { $0.range.lowerBound <= offset }.max { $0.range.lowerBound < $1.range.lowerBound }
        return before?.start ?? start
    }
}

/// The transcript as lines to follow during playback: the word being said is highlighted
/// when the provider timed words, else the phrase it is in.
public enum PlaybackTranscript {
    public struct Position: Equatable, Sendable {
        public var line: Int
        /// Nil between two words or phrases of the line.
        public var span: Int?

        public init(line: Int, span: Int?) {
            self.line = line
            self.span = span
        }
    }

    /// Lines from display segments (names applied, not merged), one per speaker turn like transcript.md.
    public static func lines(from segments: [Segment], defaultSpeaker: String = "Unknown") -> [PlaybackLine] {
        TranscriptFormatter.turns(segments).map { group in
            var text = ""
            var spans: [PlaybackSpan] = []
            for seg in group {
                if !text.isEmpty { text += " " }
                let offset = text.count
                text += seg.text
                let words = seg.words ?? []
                let found = zip(words, locate(words.map(\.text), in: seg.text)).compactMap { word, range -> PlaybackSpan? in
                    range.map { PlaybackSpan(start: word.start, end: word.end, range: (offset + $0.lowerBound)..<(offset + $0.upperBound),
                                             isWord: true) }
                }
                spans += found.isEmpty
                    ? [PlaybackSpan(start: seg.start, end: seg.end, range: offset..<(offset + seg.text.count), isWord: false)]
                    : found
            }
            return PlaybackLine(start: group[0].start, end: group.map(\.end).max() ?? group[0].end,
                                speaker: group[0].speaker ?? defaultSpeaker, text: text,
                                spans: spans.sorted { $0.start < $1.start })
        }
    }

    /// Lines from transcript.md turns, for calls without segments.json: each turn is one
    /// phrase lasting until the next one starts.
    public static func lines(from blocks: [TranscriptBlock]) -> [PlaybackLine] {
        blocks.enumerated().map { i, b in
            let end = i + 1 < blocks.count ? max(b.start, blocks[i + 1].start) : .infinity
            return PlaybackLine(start: b.start, end: end, speaker: b.speaker, text: b.text,
                                spans: [PlaybackSpan(start: b.start, end: end, range: 0..<b.text.count, isWord: false)])
        }
    }

    /// The line and span being played at `time`. A line or span stays current for
    /// `tolerance` seconds after it ends, so short pauses don't make the highlight blink.
    public static func position(at time: Double, in lines: [PlaybackLine], tolerance: Double = 1) -> Position? {
        let started = lastIndex(startingBy: time, count: lines.count) { lines[$0].start }
        guard started >= 0 else { return nil }
        // Lines can overlap (two people talking): take the latest one still going.
        for i in stride(from: started, through: max(0, started - 4), by: -1) where time < lines[i].end + tolerance {
            let spans = lines[i].spans
            let s = lastIndex(startingBy: time, count: spans.count) { spans[$0].start }
            let span = s >= 0 && time < spans[s].end + tolerance ? s : nil
            return Position(line: i, span: span)
        }
        return nil
    }

    /// Binary search: the last index whose start is at or before `time`, -1 if none.
    private static func lastIndex(startingBy time: Double, count: Int, start: (Int) -> Double) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if start(mid) <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// Character ranges of `words` in `text`, searched in order. Nil for a word not found
    /// shortly after the previous one, so one missing word doesn't lose the ones after it.
    public static func locate(_ words: [String], in text: String) -> [Range<Int>?] {
        var result: [Range<Int>?] = []
        var cursor = text.startIndex
        var cursorOffset = 0
        for word in words {
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, cursor < text.endIndex else {
                result.append(nil)
                continue
            }
            let limit = text.index(cursor, offsetBy: w.count + 24, limitedBy: text.endIndex) ?? text.endIndex
            guard let r = text.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<limit) else {
                result.append(nil)
                continue
            }
            let lower = cursorOffset + text.distance(from: cursor, to: r.lowerBound)
            let upper = lower + text.distance(from: r.lowerBound, to: r.upperBound)
            result.append(lower..<upper)
            cursor = r.upperBound
            cursorOffset = upper
        }
        return result
    }
}
