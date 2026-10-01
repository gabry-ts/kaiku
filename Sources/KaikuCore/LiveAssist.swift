import Foundation

/// Prompts and pacing for the summary and the questions next to the live transcript.
/// The summary is cumulative: each update sends the bullets so far and only the lines
/// heard since, and the model returns the whole list with the new points merged in.
public enum LiveAssist {
    /// The answer asked for when the transcript doesn't say.
    public static let notMentioned = "Not mentioned in the call so far."
    public static let maxBullets = 20
    /// Longest transcript sent with a question; longer ones keep their end.
    public static let maxTranscriptCharacters = 100_000
    /// Earlier questions sent along, so follow-ups make sense.
    public static let historyCount = 3

    /// One question and its answer, nil while waiting.
    public struct Exchange: Identifiable, Equatable, Sendable {
        public let id: Int
        public let question: String
        public var answer: String?

        public init(id: Int, question: String, answer: String? = nil) {
            self.id = id
            self.question = question
            self.answer = answer
        }
    }

    /// When the summary is brought up to date.
    public struct Pace: Equatable, Sendable {
        /// New words that are worth an update...
        public var minWords = 80
        /// ...once this many seconds passed since the last one.
        public var minInterval: Double = 45
        /// After this long, fewer words are enough.
        public var idleInterval: Double = 120
        public var idleWords = 15

        public init() {}
    }

    /// - Parameter sinceLast: seconds since the last update, or since the call started.
    public static func shouldSummarize(pendingWords: Int, sinceLast: Double, pace: Pace = Pace()) -> Bool {
        if sinceLast >= pace.idleInterval { return pendingWords >= pace.idleWords }
        return sinceLast >= pace.minInterval && pendingWords >= pace.minWords
    }

    /// Final lines not in the summary yet, in time order. Lines are matched by id, since a
    /// final line can land before lines already summarized.
    public static func pending(_ transcript: LiveTranscript, summarized: Set<Int>) -> [LiveLine] {
        transcript.finals.filter { !summarized.contains($0.id) }
    }

    public static func wordCount(_ lines: [LiveLine]) -> Int {
        lines.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Lines as plain text, one per row: `[00:01:05] Me: text`.
    public static func text(_ lines: [LiveLine]) -> String {
        lines.map { "[\(TranscriptFormatter.timestamp($0.start))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }

    /// The transcript for a question, cut at the start when longer than `limit`.
    public static func transcript(_ lines: [LiveLine], limit: Int = maxTranscriptCharacters) -> String {
        let full = text(lines)
        guard full.count > limit else { return full }
        var tail = String(full.suffix(limit))
        // Start on a whole line.
        if let newline = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]) }
        return "[Earlier part of the call left out]\n" + tail
    }

    public static func summaryPrompt(bullets: [String], newLines: String) -> String {
        let current = bullets.isEmpty ? "(none yet)" : markdown(bullets)
        return """
        You keep a running bullet-point summary of a call that is still going on.
        Below are the current bullets and the newest part of the transcript ("Me" is the user, "Them" the other side).

        Return the complete updated list:
        - Keep the current bullets unless the new lines correct or extend them; merge duplicates.
        - Add the new topics, decisions, numbers and action items from the new lines.
        - At most \(maxBullets) bullets, short ones, each line starting with "- ". Nothing else, no headings.
        - Write in the same language as the transcript. Do not invent anything.

        Current bullets:
        \(current)

        New lines:
        \(newLines)
        """
    }

    public static func askPrompt(transcript: String, history: [Exchange], question: String) -> String {
        let earlier = history.suffix(historyCount).compactMap { e in e.answer.map { "Q: \(e.question)\nA: \($0)" } }
        var prompt = """
        Answer a question about a call that is still going on, using only its transcript below ("Me" is the user, "Them" the other side).
        Answer in one to three short sentences, in the language of the question.
        If the transcript doesn't contain the answer, reply exactly "\(notMentioned)" (translated into the language of the question). Never guess or use outside knowledge.

        Transcript:
        \(transcript.isEmpty ? "(nothing said yet)" : transcript)
        """
        if !earlier.isEmpty { prompt += "\n\nEarlier questions:\n" + earlier.joined(separator: "\n") }
        prompt += "\n\nQuestion: \(question)"
        return prompt
    }

    /// The bullets of a model reply: lines starting with "- ", "* " or "•", at most `limit`.
    public static func parseBullets(_ text: String, limit: Int = maxBullets) -> [String] {
        let bullets = text.components(separatedBy: .newlines).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("•") else { return nil }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        return Array(bullets.prefix(limit))
    }

    public static func markdown(_ bullets: [String]) -> String {
        bullets.map { "- " + $0 }.joined(separator: "\n")
    }
}
