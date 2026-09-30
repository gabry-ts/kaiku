import Foundation

/// Who is talking in the live transcript: one speaker per recorded track.
public enum LiveSpeaker: String, CaseIterable, Codable, Sendable {
    /// The microphone track.
    case me
    /// The system audio track.
    case them

    public var label: String { self == .me ? "Me" : "Them" }
}

/// One piece of speech in the live transcript.
public struct LiveLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public var speaker: LiveSpeaker
    /// Seconds from the start of the recording.
    public var start: Double
    public var end: Double
    public var text: String
    /// False while the engine may still change the text.
    public var isFinal: Bool
}

/// The text heard so far while recording. Each track has at most one partial line, which
/// the engine keeps rewriting until it becomes final; final lines stay in time order
/// across the two tracks.
public struct LiveTranscript: Equatable, Sendable {
    public private(set) var finals: [LiveLine] = []
    private var partials: [LiveSpeaker: LiveLine] = [:]
    private var nextID = 0

    public init() {}

    public var isEmpty: Bool { finals.isEmpty && partials.isEmpty }

    /// Replaces the partial line of `speaker`. Empty text removes it.
    /// - Parameter time: where the line starts, used when the track has no partial yet.
    public mutating func setPartial(_ text: String, speaker: LiveSpeaker, at time: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            partials[speaker] = nil
            return
        }
        if var line = partials[speaker] {
            line.text = clean
            line.end = max(line.end, time)
            partials[speaker] = line
        } else {
            partials[speaker] = LiveLine(id: takeID(), speaker: speaker, start: time, end: time, text: clean, isFinal: false)
        }
    }

    /// Adds a final line, which replaces the partial of its track.
    public mutating func addFinal(_ text: String, speaker: LiveSpeaker, start: Double, end: Double) {
        let partial = partials.removeValue(forKey: speaker)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let line = LiveLine(id: partial?.id ?? takeID(), speaker: speaker, start: start, end: max(start, end),
                            text: clean, isFinal: true)
        // After the lines that start at the same time or earlier, so tracks interleave.
        let index = finals.lastIndex(where: { $0.start <= start }).map { $0 + 1 } ?? 0
        finals.insert(line, at: index)
    }

    /// Turns what is still partial into final lines, when the engine stops.
    public mutating func finalizePartials() {
        for line in partials.values.sorted(by: { $0.start < $1.start }) {
            addFinal(line.text, speaker: line.speaker, start: line.start, end: line.end)
        }
    }

    /// Final lines in time order, then what is being said right now.
    public var lines: [LiveLine] {
        finals + partials.values.sorted { ($0.start, $0.speaker.rawValue) < ($1.start, $1.speaker.rawValue) }
    }

    public func lastLines(_ count: Int) -> [LiveLine] {
        Array(lines.suffix(max(0, count)))
    }

    /// The final lines as transcript segments, the form recordings are saved in.
    public func segments() -> [Segment] {
        finals.map { Segment(start: $0.start, end: $0.end, speaker: $0.speaker.label, text: $0.text) }
    }

    public func result(language: String? = nil) -> TranscriptionResult {
        TranscriptionResult(segments: segments(), detectedLanguage: language)
    }

    private mutating func takeID() -> Int {
        nextID += 1
        return nextID
    }
}

/// Maps an engine's own audio clock to recording time. An engine is fed the audio back to
/// back, while the recording can have silence added where a source changed; every such
/// jump is noted here, so lines keep the time they have in the recorded files.
public struct LiveTimeline: Equatable, Sendable {
    private var anchors: [(fed: Double, recorded: Double)] = []
    private var fed: Double = 0

    public init() {}

    public static func == (a: LiveTimeline, b: LiveTimeline) -> Bool {
        a.fed == b.fed && a.anchors.elementsEqual(b.anchors) { $0 == $1 }
    }

    /// Call for every buffer handed to the engine, in order.
    /// - Parameters:
    ///   - recorded: where the buffer starts in the recording.
    ///   - duration: its length in seconds.
    public mutating func note(recorded: Double, duration: Double) {
        if anchors.isEmpty || abs(recordedTime(fed) - recorded) > 0.2 {
            anchors.append((fed, recorded))
        }
        fed += duration
    }

    /// The recording time of a moment on the engine's clock.
    public func recordedTime(_ time: Double) -> Double {
        guard let anchor = anchors.last(where: { $0.fed <= time }) ?? anchors.first else { return time }
        return anchor.recorded + (time - anchor.fed)
    }
}
