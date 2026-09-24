import Foundation
import KaikuCore

enum RecordingStatus: String, Codable {
    case recording, paused, transcribing, done, error
    /// Audio saved after the app quit or crashed mid-call; not transcribed yet.
    case recovered
}

/// Persisted as meta.json inside each recording folder.
struct RecordingMeta: Codable {
    var title: String
    var date: Date
    var durationSeconds: Double
    /// "auto" or the ISO code chosen for this call.
    var language: String
    var detectedLanguage: String?
    var provider: String?
    var model: String?
    var status: RecordingStatus
    var error: String?
    var audioDeleted: Bool?
    /// Display names for raw speaker labels, e.g. ["Speaker 1": "Anna"].
    var speakerNames: [String: String]?
    /// Pauses during the recording (audio is not recorded while paused).
    var pauses: [PauseInterval]?
    /// Markers in the recorded audio.
    var bookmarks: [Bookmark]?
    /// Model id used for transcription, e.g. "whisper-1" (for the cost estimate).
    var modelID: String?
    /// Seconds of audio actually sent for transcription (after silence trimming).
    var transcribedSeconds: Double?
    /// Estimated transcription cost in USD; nil when no price is known.
    var estimatedCostUSD: Double?
    /// Calendar event matched when the recording started.
    var calendarEvent: CalendarEventInfo?
    /// When all microphones were muted from Kaiku during the recording.
    var muteIntervals: [MuteInterval]?
    /// Where the call audio played, per stretch of the recording (for echo removal).
    var outputRoutes: [OutputRoute]?
    /// User tags, e.g. project names.
    var tags: [String]?
    /// Model that wrote summary.md, e.g. "Anthropic (claude-sonnet-5)".
    var summaryModel: String?
}

/// A recording folder on disk.
struct RecordingFolder: Identifiable, Hashable {
    let url: URL
    var id: String { key }
    /// Normalized path used for comparisons.
    var key: String { url.standardizedFileURL.path }

    static let metaName = "meta.json"
    static let transcriptName = "transcript.md"
    static let micName = "mic.m4a"
    static let systemName = "system.m4a"
    static let mixedName = "mixed.m4a"
    static let segmentsName = "segments.json"
    static let summaryName = "summary.md"
    /// Crash-safe files written while recording, converted to .m4a on stop.
    static let micRawName = "mic.caf"
    static let systemRawName = "system.caf"

    var metaURL: URL { url.appendingPathComponent(Self.metaName) }
    var transcriptURL: URL { url.appendingPathComponent(Self.transcriptName) }
    var micURL: URL { url.appendingPathComponent(Self.micName) }
    var systemURL: URL { url.appendingPathComponent(Self.systemName) }
    var mixedURL: URL { url.appendingPathComponent(Self.mixedName) }
    var segmentsURL: URL { url.appendingPathComponent(Self.segmentsName) }
    var summaryURL: URL { url.appendingPathComponent(Self.summaryName) }
    var micRawURL: URL { url.appendingPathComponent(Self.micRawName) }
    var systemRawURL: URL { url.appendingPathComponent(Self.systemRawName) }

    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }
    var hasSummary: Bool { FileManager.default.fileExists(atPath: summaryURL.path) }
    var summary: String? { try? String(contentsOf: summaryURL, encoding: .utf8) }

    /// Finished audio files (.m4a).
    var audioURLs: [URL] {
        [micURL, systemURL, mixedURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every audio file in the folder, including unconverted recordings.
    var allAudioURLs: [URL] {
        [micURL, systemURL, mixedURL, micRawURL, systemRawURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var audioBytes: Int64 { allAudioURLs.reduce(0) { $0 + Self.fileSize($1) } }

    /// Size of everything in the folder.
    var totalBytes: Int64 {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.reduce(0) { $0 + Self.fileSize($1) }
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func loadMeta() -> RecordingMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? Self.decoder.decode(RecordingMeta.self, from: data)
    }

    func saveMeta(_ meta: RecordingMeta) throws {
        try Self.encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    /// Raw segments (original speaker labels, unmerged) saved after transcription.
    func loadSegments() -> [Segment]? {
        guard let data = try? Data(contentsOf: segmentsURL) else { return nil }
        return try? JSONDecoder().decode([Segment].self, from: data)
    }

    func saveSegments(_ segments: [Segment]) throws {
        try Self.encoder.encode(segments).write(to: segmentsURL, options: .atomic)
    }

    func updateMeta(_ change: (inout RecordingMeta) -> Void) {
        guard var m = loadMeta() else { return }
        change(&m)
        try? saveMeta(m)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// All recording folders under the base folder that contain a meta.json.
    static func scan(base: URL) -> [RecordingFolder] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { RecordingFolder(url: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.metaURL.path) }
    }
}
