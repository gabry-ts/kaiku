import Foundation

/// One track's provider result, kept after a failed run so that trying again
/// does not upload (and pay for) it a second time. Segments are already on the
/// original timeline and have no Me/Others labels yet.
public struct TrackCache: Codable, Equatable, Sendable {
    /// Everything that must match for the result to be reused.
    public struct Key: Codable, Equatable, Sendable {
        public struct Trim: Codable, Equatable, Sendable {
            public var thresholdDB: Double
            public var minDuration: Double
            public var padding: Double
        }

        /// Provider name including the model.
        public var provider: String
        public var language: String?
        /// nil when silence trimming was off.
        public var trim: Trim?
        public var audioBytes: Int64
        public var audioModified: Double

        public init(provider: String, language: String?, trim: SilenceTrimmer.Options?, audioBytes: Int64, audioModified: Double) {
            self.provider = provider
            self.language = language
            self.trim = trim.map { Trim(thresholdDB: $0.thresholdDB, minDuration: $0.minDuration, padding: $0.padding) }
            self.audioBytes = audioBytes
            self.audioModified = audioModified
        }
    }

    public var key: Key
    public var segments: [Segment]
    public var detectedLanguage: String?
    /// Seconds sent to the provider, for the cost estimate.
    public var seconds: Double

    public init(key: Key, segments: [Segment], detectedLanguage: String?, seconds: Double) {
        self.key = key
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.seconds = seconds
    }

    /// The saved result, if it was made with exactly `key`.
    public static func reusable(_ data: Data?, for key: Key) -> TrackCache? {
        guard let data, let cache = try? JSONDecoder().decode(TrackCache.self, from: data), cache.key == key else { return nil }
        return cache
    }
}
