import Foundation

/// Stops a recording left running by mistake: no sound on either track for too long,
/// or longer than the maximum length. Times are recorded time, so pauses don't count.
public struct RecordingGuard: Sendable {
    public enum Reason: Equatable, Sendable {
        case silence
        case maxDuration
    }

    /// Peak level below which a track counts as silent (about -45 dBFS).
    public static let silenceLevel: Float = 0.0056

    /// Seconds without sound before stopping; 0 is never.
    public var silenceLimit: Double
    /// Longest recording in seconds; 0 is no limit.
    public var maxDuration: Double
    private var lastSound: Double = 0

    public init(silenceLimit: Double = 0, maxDuration: Double = 0) {
        self.silenceLimit = silenceLimit
        self.maxDuration = maxDuration
    }

    /// Why the recording should stop now, if it should.
    public mutating func update(recorded: Double, micLevel: Float, systemLevel: Float) -> Reason? {
        if max(micLevel, systemLevel) >= Self.silenceLevel { lastSound = recorded }
        if maxDuration > 0, recorded >= maxDuration { return .maxDuration }
        if silenceLimit > 0, recorded - lastSound >= silenceLimit { return .silence }
        return nil
    }

    /// "15 minutes", "1 hour", "4 hours".
    public static func describe(seconds: Int) -> String {
        if seconds >= 3600, seconds % 3600 == 0 {
            let h = seconds / 3600
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        let m = max(1, seconds / 60)
        return m == 1 ? "1 minute" : "\(m) minutes"
    }
}
