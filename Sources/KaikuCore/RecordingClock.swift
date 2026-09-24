import Foundation

/// A pause during a recording. `offset` is the recorded time (audio position) when it started.
public struct PauseInterval: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date?
    public var offset: Double

    public init(start: Date, end: Date? = nil, offset: Double) {
        self.start = start
        self.end = end
        self.offset = offset
    }
}

/// A marker in the recorded audio. `time` is the position in the audio, pauses excluded.
public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: Double
    public var label: String
    public var createdAt: Date

    public init(id: UUID = UUID(), time: Double, label: String = "", createdAt: Date = Date()) {
        self.id = id
        self.time = time
        self.label = label
        self.createdAt = createdAt
    }

    /// Label for display, "Bookmark" when empty.
    public var displayLabel: String {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Bookmark" : t
    }
}

/// Wall clock to recorded time, accounting for pauses.
public struct RecordingClock: Equatable, Sendable {
    public let start: Date
    public private(set) var pauses: [PauseInterval]

    public init(start: Date, pauses: [PauseInterval] = []) {
        self.start = start
        self.pauses = pauses
    }

    public var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    /// Seconds of audio recorded up to `date`.
    public func recordedTime(at date: Date) -> Double {
        var paused = 0.0
        for p in pauses where p.start < date {
            let end = min(p.end ?? date, date)
            paused += max(0, end.timeIntervalSince(p.start))
        }
        return max(0, date.timeIntervalSince(start) - paused)
    }

    public mutating func pause(at date: Date) {
        guard !isPaused else { return }
        pauses.append(PauseInterval(start: date, offset: recordedTime(at: date)))
    }

    public mutating func resume(at date: Date) {
        guard isPaused else { return }
        pauses[pauses.count - 1].end = date
    }
}
