import Foundation

/// Turns text into a vector that is close to the vectors of texts with a similar meaning.
public protocol TextEmbedder: Sendable {
    /// True when the embedder has a model for `language` (a code such as "it" or "en").
    func supports(language: String) -> Bool
    /// The vector of `text` in `language`, or nil when it can't be embedded.
    func embed(_ text: String, language: String) -> [Float]?
}

/// A few sentences of a transcript, the unit that is embedded and found.
public struct Passage: Codable, Equatable, Sendable {
    /// Where the passage starts in the audio, in seconds.
    public var start: Double
    public var speaker: String?
    public var text: String

    public init(start: Double, speaker: String? = nil, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

/// Splits a transcript into passages of about three sentences.
public enum PassageChunker {
    public static let maxSentences = 3
    public static let maxCharacters = 450

    /// Passages of whole sentences, never longer than the limits, in time order. Short turns
    /// are joined with the next ones; a passage starts at its first sentence, whose time is
    /// estimated from its place in the turn.
    public static func chunks(from turns: [Segment], maxSentences: Int = maxSentences,
                              maxCharacters: Int = maxCharacters) -> [Passage] {
        var passages: [Passage] = []
        var current: Passage?
        var count = 0
        func flush() {
            if let p = current { passages.append(p) }
            current = nil
            count = 0
        }
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            let total = max(1, turn.text.count)
            var offset = 0
            for sentence in sentences(turn.text) {
                let start = turn.start + (turn.end - turn.start) * Double(offset) / Double(total)
                offset += sentence.count
                if let p = current, count >= maxSentences || p.text.count + sentence.count >= maxCharacters { flush() }
                if current == nil {
                    current = Passage(start: start, speaker: turn.speaker, text: sentence)
                } else {
                    current?.text += " " + sentence
                }
                count += 1
            }
        }
        flush()
        return passages
    }

    /// The sentences of `text`, trimmed, without the empty ones.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let s = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { result.append(s) }
        }
        return result
    }
}

/// The vectors of a call's passages, as stored in the call folder.
public struct SemanticIndex: Codable, Equatable, Sendable {
    /// Bump when chunking or the way vectors are made changes, so stored indexes are rebuilt.
    public static let currentVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public var passage: Passage
        public var vector: [Float]

        public init(passage: Passage, vector: [Float]) {
            self.passage = passage
            self.vector = vector
        }
    }

    public var version: Int
    /// The language of the model the vectors come from.
    public var language: String
    /// Identifies the passages the vectors were made from.
    public var fingerprint: String
    public var entries: [Entry]

    public init(version: Int = SemanticIndex.currentVersion, language: String, fingerprint: String, entries: [Entry]) {
        self.version = version
        self.language = language
        self.fingerprint = fingerprint
        self.entries = entries
    }

    /// True when the index no longer matches the transcript or the embedding language, or was
    /// made by an older version.
    public func isStale(language: String, fingerprint: String) -> Bool {
        version != Self.currentVersion || self.language != language || self.fingerprint != fingerprint
    }

    /// A stable summary of `passages`: the same texts and times give the same value.
    public static func fingerprint(of passages: [Passage]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) {
            for b in bytes { hash = (hash ^ UInt64(b)) &* 0x100_0000_01b3 }
        }
        for p in passages {
            mix(p.text.utf8)
            mix(String(Int(p.start)).utf8)
        }
        return String(hash, radix: 16) + "-\(passages.count)"
    }
}

/// A passage found for a query.
public struct SemanticMatch: Equatable, Sendable {
    public var callID: String
    public var passage: Passage
    public var score: Float

    public init(callID: String, passage: Passage, score: Float) {
        self.callID = callID
        self.passage = passage
        self.score = score
    }
}

public enum SemanticRanker {
    /// Passages scoring below this are not related enough to the query to be shown.
    public static let minimumScore: Float = 0.3

    /// 1 for vectors pointing the same way, 0 for unrelated ones; 0 when either is empty,
    /// null or of another size.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// The best passages of `indexes` for the query vectors (by language), best first. An
    /// index is only compared with the query vector of its own language.
    public static func rank(queries: [String: [Float]], indexes: [(callID: String, index: SemanticIndex)],
                            limit: Int = 30, minimumScore: Float = minimumScore) -> [SemanticMatch] {
        var matches: [SemanticMatch] = []
        for (callID, index) in indexes {
            guard let query = queries[index.language] else { continue }
            for entry in index.entries {
                let score = cosine(query, entry.vector)
                if score >= minimumScore { matches.append(SemanticMatch(callID: callID, passage: entry.passage, score: score)) }
            }
        }
        matches.sort { $0.score > $1.score }
        return Array(matches.prefix(max(0, limit)))
    }
}
