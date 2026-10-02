import Foundation

/// The text of a call that Spotlight indexes.
public enum SpotlightText {
    /// What was said, without timestamps and speaker names, cut at `limit` characters
    /// between words.
    public static func snippet(fromTranscript markdown: String, limit: Int = 4000) -> String {
        let words = TranscriptFormatter.parseBlocks(markdown)
            .map(\.text)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
        var out = ""
        for word in words {
            let next = out.isEmpty ? word.count : out.count + 1 + word.count
            if next > limit { break }
            out += out.isEmpty ? String(word) : " " + word
        }
        return out
    }
}
