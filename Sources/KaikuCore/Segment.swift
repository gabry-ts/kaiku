import Foundation

/// A timed piece of transcribed speech.
public struct Segment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String?
    public var text: String
    /// Set on microphone segments that repeat the call audio picked up from the speakers.
    /// Kept in segments.json (so it can be undone) but hidden everywhere else.
    public var droppedAsEcho: Bool?
    /// The time of each word, from providers that give it. Nil for the others and for calls
    /// transcribed before words were kept.
    public var words: [Word]?

    /// A spoken word and where it is in the audio, in seconds.
    public struct Word: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public init(start: Double, end: Double, speaker: String? = nil, text: String, droppedAsEcho: Bool? = nil,
                words: [Word]? = nil) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.droppedAsEcho = droppedAsEcho
        self.words = words
    }
}

/// Output of a single provider call on a single audio file.
public struct TranscriptionResult: Sendable {
    public var segments: [Segment]
    /// Language reported by the provider, if any (e.g. "it", "ita", "italian").
    public var detectedLanguage: String?

    public init(segments: [Segment], detectedLanguage: String? = nil) {
        self.segments = segments
        self.detectedLanguage = detectedLanguage
    }
}

/// A word with timing, as returned by word-level providers.
public struct TimedWord: Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var speaker: String?

    public init(text: String, start: Double, end: Double, speaker: String?) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}
