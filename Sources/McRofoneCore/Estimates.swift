import Foundation

/// Transcription cost estimate from the minutes actually sent to the provider.
public enum CostEstimator {
    /// Official list prices in USD per hour of audio (checked September 2026).
    /// Editable in Settings; these are only the defaults.
    public static let defaultPricesPerHour: [String: Double] = [
        // ElevenLabs Scribe (elevenlabs.io/pricing/api: Scribe v2 $0.22/hour; v1 assumed equal).
        "scribe_v2": 0.22,
        "scribe_v1": 0.22,
        // OpenAI (developers.openai.com/api/docs/pricing, per-minute estimates × 60).
        "gpt-4o-transcribe": 0.36,
        "gpt-4o-mini-transcribe": 0.18,
        "gpt-4o-transcribe-diarize": 0.36,
        "gpt-transcribe": 0.27,
        "whisper-1": 0.36,
        // Groq (console.groq.com/docs/model/...).
        "whisper-large-v3-turbo": 0.04,
        "whisper-large-v3": 0.111,
    ]

    /// Price per hour for `model`: user override first, then the default table, else nil.
    public static func pricePerHour(model: String, overrides: [String: Double]) -> Double? {
        overrides[model] ?? defaultPricesPerHour[model]
    }

    /// USD for `seconds` of audio, rounded to 1/10000 of a dollar.
    public static func estimate(seconds: Double, pricePerHour: Double) -> Double {
        ((max(0, seconds) / 3600 * pricePerHour) * 10_000).rounded() / 10_000
    }

    /// "$0.12", "<$0.01" or "$0.00".
    public static func format(_ usd: Double) -> String {
        if usd == 0 { return "$0.00" }
        if usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }
}

/// Which calls the audio cleanup would touch.
public enum StorageCleanup {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var date: Date
        public var audioBytes: Int64
        public var hasTranscript: Bool
        public var audioDeleted: Bool

        public init(id: String, date: Date, audioBytes: Int64, hasTranscript: Bool, audioDeleted: Bool) {
            self.id = id
            self.date = date
            self.audioBytes = audioBytes
            self.hasTranscript = hasTranscript
            self.audioDeleted = audioDeleted
        }
    }

    /// Calls older than `days` that still have audio and already have a transcript.
    /// Calls without a transcript keep their audio, so they can still be transcribed.
    public static func select(_ items: [Candidate], olderThanDays days: Int, now: Date) -> [Candidate] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items.filter { $0.date < cutoff && $0.hasTranscript && !$0.audioDeleted && $0.audioBytes > 0 }
    }
}
