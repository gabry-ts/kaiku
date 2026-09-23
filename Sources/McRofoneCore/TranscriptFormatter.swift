import Foundation

public enum TranscriptFormatter {
    /// Formats seconds as HH:MM:SS.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Sorts segments by start time and merges consecutive segments of the same speaker.
    public static func merge(_ segments: [Segment]) -> [Segment] {
        let sorted = segments
            .map { s -> Segment in
                var c = s
                c.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return c
            }
            .filter { !$0.text.isEmpty }
            .enumerated()
            .sorted { a, b in
                a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start
            }
            .map(\.element)

        var merged: [Segment] = []
        for seg in sorted {
            if var last = merged.last, last.speaker == seg.speaker {
                last.text += " " + seg.text
                last.end = max(last.end, seg.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    /// Renders the transcript body, one paragraph per speaker turn, with bookmarks
    /// placed after the turns that start at or before them.
    public static func body(_ merged: [Segment], bookmarks: [Bookmark] = [], defaultSpeaker: String = "Unknown") -> String {
        var paragraphs: [String] = []
        var pending = bookmarks.sorted { $0.time < $1.time }[...]
        for seg in merged {
            while let b = pending.first, b.time < seg.start {
                paragraphs.append(bookmarkLine(b))
                pending = pending.dropFirst()
            }
            paragraphs.append("**[\(timestamp(seg.start))] \(seg.speaker ?? defaultSpeaker):** \(seg.text)")
        }
        paragraphs += pending.map(bookmarkLine)
        return paragraphs.joined(separator: "\n\n")
    }

    /// `🔖 [00:12:03] Bookmark: label`, or `🔖 [00:12:03] Bookmark` without a label.
    public static func bookmarkLine(_ b: Bookmark) -> String {
        let label = b.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return "🔖 [\(timestamp(b.time))] Bookmark" + (label.isEmpty ? "" : ": \(label)")
    }

    public struct Header {
        public var title: String
        public var date: Date
        public var durationSeconds: Double
        public var provider: String
        public var language: String
        public var audioFiles: [String]
        public var tags: [String]

        public init(title: String, date: Date, durationSeconds: Double, provider: String, language: String, audioFiles: [String],
                    tags: [String] = []) {
            self.tags = tags
            self.title = title
            self.date = date
            self.durationSeconds = durationSeconds
            self.provider = provider
            self.language = language
            self.audioFiles = audioFiles
        }
    }

    public static func markdown(header h: Header, merged: [Segment], bookmarks: [Bookmark] = []) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = [
            "# \(h.title)",
            "",
            "- **Date:** \(df.string(from: h.date))",
            "- **Duration:** \(timestamp(h.durationSeconds))",
            "- **Provider:** \(h.provider)",
            "- **Language:** \(h.language)",
        ]
        if !h.tags.isEmpty {
            lines.append("- **Tags:** " + h.tags.joined(separator: ", "))
        }
        if !h.audioFiles.isEmpty {
            lines.append("- **Audio:** " + h.audioFiles.joined(separator: ", "))
        }
        lines += ["", "---", ""]
        let text = body(merged, bookmarks: bookmarks)
        lines.append(merged.isEmpty ? (text.isEmpty ? "_No speech detected._" : "_No speech detected._\n\n" + text) : text)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Groups timed words into segments, splitting on speaker change, long pauses,
    /// or sentence ends once a segment gets long.
    public static func group(words: [TimedWord], maxGap: Double = 1.5, softMaxDuration: Double = 20) -> [Segment] {
        var result: [Segment] = []
        var current: Segment?
        for w in words {
            let token = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            if var c = current {
                let endsSentence = c.text.last.map { ".?!".contains($0) } ?? false
                let split = c.speaker != w.speaker
                    || w.start - c.end > maxGap
                    || (endsSentence && c.end - c.start > softMaxDuration)
                if split {
                    result.append(c)
                    current = Segment(start: w.start, end: w.end, speaker: w.speaker, text: token)
                } else {
                    c.text += (isPunctuation(token) ? "" : " ") + token
                    c.end = w.end
                    current = c
                }
            } else {
                current = Segment(start: w.start, end: w.end, speaker: w.speaker, text: token)
            }
        }
        if let c = current { result.append(c) }
        return result
    }

    private static func isPunctuation(_ s: String) -> Bool {
        s.allSatisfy { ",.;:!?)".contains($0) }
    }

    /// Maps raw provider speaker ids (e.g. "speaker_0", "A") to "Speaker 1", "Speaker 2"...
    /// in order of first appearance.
    public static func normalizeSpeakers(_ segments: [Segment], prefix: String = "Speaker") -> [Segment] {
        var map: [String: String] = [:]
        return segments.map { s in
            guard let raw = s.speaker, !raw.isEmpty else { return s }
            if map[raw] == nil { map[raw] = "\(prefix) \(map.count + 1)" }
            var c = s
            c.speaker = map[raw]
            return c
        }
    }
}

/// A speaker turn parsed back from transcript.md.
public struct TranscriptBlock: Equatable, Sendable {
    public var start: Double
    public var speaker: String
    public var text: String

    public init(start: Double, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

public extension TranscriptFormatter {
    /// Parses `**[HH:MM:SS] Speaker:** text` paragraphs from a transcript.md.
    static func parseBlocks(_ markdown: String) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for paragraph in markdown.components(separatedBy: "\n\n") {
            let line = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("**["), let close = line.range(of: "] "),
                  let end = line.range(of: ":** ", range: close.upperBound..<line.endIndex) else { continue }
            let stamp = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]
            let parts = stamp.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { continue }
            let start = parts[0] * 3600 + parts[1] * 60 + parts[2]
            let speaker = String(line[close.upperBound..<end.lowerBound])
            let text = String(line[end.upperBound...])
            blocks.append(TranscriptBlock(start: start, speaker: speaker, text: text))
        }
        return blocks
    }
}
