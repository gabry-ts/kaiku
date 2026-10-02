import Foundation

public enum RecordingStatus: String, Codable, Sendable {
    case recording, paused, transcribing, done, error
    /// Audio saved after the app quit or crashed mid-call; not transcribed yet.
    case recovered
}

/// Persisted as meta.json inside each recording folder.
public struct RecordingMeta: Codable, Sendable {
    public var title: String
    public var date: Date
    public var durationSeconds: Double
    /// "auto" or the ISO code chosen for this call.
    public var language: String
    public var detectedLanguage: String?
    public var provider: String?
    public var model: String?
    public var status: RecordingStatus
    public var error: String?
    public var audioDeleted: Bool?
    /// Display names for raw speaker labels, e.g. ["Speaker 1": "Anna"].
    public var speakerNames: [String: String]?
    /// Pauses during the recording (audio is not recorded while paused).
    public var pauses: [PauseInterval]?
    /// Markers in the recorded audio.
    public var bookmarks: [Bookmark]?
    /// Model id used for transcription, e.g. "whisper-1" (for the cost estimate).
    public var modelID: String?
    /// Seconds of audio actually sent for transcription (after silence trimming).
    public var transcribedSeconds: Double?
    /// Estimated transcription cost in USD; nil when no price is known.
    public var estimatedCostUSD: Double?
    /// Calendar event matched when the recording started.
    public var calendarEvent: CalendarEventInfo?
    /// When all microphones were muted from Kaiku during the recording.
    public var muteIntervals: [MuteInterval]?
    /// Where the call audio played, per stretch of the recording (for echo removal).
    public var outputRoutes: [OutputRoute]?
    /// User tags, e.g. project names.
    public var tags: [String]?
    /// Model that wrote summary.md, e.g. "Anthropic (claude-sonnet-5)".
    public var summaryModel: String?
    /// Where the call came from, e.g. "WhatsApp" or "Manual"; editable in the Library.
    public var source: String?
    /// App the call ran in, e.g. "Google Chrome" for WhatsApp Web.
    public var sourceApp: String?

    public init(title: String, date: Date, durationSeconds: Double, language: String, detectedLanguage: String? = nil,
                provider: String? = nil, model: String? = nil, status: RecordingStatus, error: String? = nil,
                audioDeleted: Bool? = nil, speakerNames: [String: String]? = nil, pauses: [PauseInterval]? = nil,
                bookmarks: [Bookmark]? = nil, modelID: String? = nil, transcribedSeconds: Double? = nil,
                estimatedCostUSD: Double? = nil, calendarEvent: CalendarEventInfo? = nil, muteIntervals: [MuteInterval]? = nil,
                outputRoutes: [OutputRoute]? = nil, tags: [String]? = nil, summaryModel: String? = nil,
                source: String? = nil, sourceApp: String? = nil) {
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        self.language = language
        self.detectedLanguage = detectedLanguage
        self.provider = provider
        self.model = model
        self.status = status
        self.error = error
        self.audioDeleted = audioDeleted
        self.speakerNames = speakerNames
        self.pauses = pauses
        self.bookmarks = bookmarks
        self.modelID = modelID
        self.transcribedSeconds = transcribedSeconds
        self.estimatedCostUSD = estimatedCostUSD
        self.calendarEvent = calendarEvent
        self.muteIntervals = muteIntervals
        self.outputRoutes = outputRoutes
        self.tags = tags
        self.summaryModel = summaryModel
        self.source = source
        self.sourceApp = sourceApp
    }
}

/// A recording folder on disk.
public struct RecordingFolder: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: String { key }
    /// Normalized path used for comparisons.
    public var key: String { url.standardizedFileURL.path }

    public init(url: URL) {
        self.url = url
    }

    public static let metaName = "meta.json"
    public static let transcriptName = "transcript.md"
    public static let micName = "mic.m4a"
    public static let systemName = "system.m4a"
    public static let mixedName = "mixed.m4a"
    public static let segmentsName = "segments.json"
    public static let summaryName = "summary.md"
    /// Action items taken from the call, with where each was sent.
    public static let actionItemsName = "action-items.json"
    /// Bullets written by the live window's Summary tab during the call.
    public static let liveSummaryName = "live-summary.md"
    /// Crash-safe files written while recording, converted to .m4a on stop.
    public static let micRawName = "mic.caf"
    public static let systemRawName = "system.caf"
    /// Per-track results kept only after a failed transcription (hidden).
    public static let micPartialName = ".mic.partial.json"
    public static let systemPartialName = ".system.partial.json"

    public var metaURL: URL { url.appendingPathComponent(Self.metaName) }
    public var transcriptURL: URL { url.appendingPathComponent(Self.transcriptName) }
    public var micURL: URL { url.appendingPathComponent(Self.micName) }
    public var systemURL: URL { url.appendingPathComponent(Self.systemName) }
    public var mixedURL: URL { url.appendingPathComponent(Self.mixedName) }
    public var segmentsURL: URL { url.appendingPathComponent(Self.segmentsName) }
    public var summaryURL: URL { url.appendingPathComponent(Self.summaryName) }
    public var actionItemsURL: URL { url.appendingPathComponent(Self.actionItemsName) }
    public var liveSummaryURL: URL { url.appendingPathComponent(Self.liveSummaryName) }
    public var micRawURL: URL { url.appendingPathComponent(Self.micRawName) }
    public var systemRawURL: URL { url.appendingPathComponent(Self.systemRawName) }
    public var micPartialURL: URL { url.appendingPathComponent(Self.micPartialName) }
    public var systemPartialURL: URL { url.appendingPathComponent(Self.systemPartialName) }

    public var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }
    public var hasSummary: Bool { FileManager.default.fileExists(atPath: summaryURL.path) }
    public var summary: String? { try? String(contentsOf: summaryURL, encoding: .utf8) }

    /// Finished audio files (.m4a).
    public var audioURLs: [URL] {
        [micURL, systemURL, mixedURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every audio file in the folder, including unconverted recordings.
    public var allAudioURLs: [URL] {
        [micURL, systemURL, mixedURL, micRawURL, systemRawURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var audioBytes: Int64 { allAudioURLs.reduce(0) { $0 + Self.fileSize($1) } }

    /// Size of everything in the folder.
    public var totalBytes: Int64 {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.reduce(0) { $0 + Self.fileSize($1) }
    }

    public static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    public func loadMeta() -> RecordingMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? Self.decoder.decode(RecordingMeta.self, from: data)
    }

    public func saveMeta(_ meta: RecordingMeta) throws {
        try Self.encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    /// Raw segments (original speaker labels, unmerged) saved after transcription.
    public func loadSegments() -> [Segment]? {
        guard let data = try? Data(contentsOf: segmentsURL) else { return nil }
        return try? JSONDecoder().decode([Segment].self, from: data)
    }

    public func saveSegments(_ segments: [Segment]) throws {
        try Self.encoder.encode(segments).write(to: segmentsURL, options: .atomic)
    }

    public func loadActionItems() -> [ActionItem] {
        guard let data = try? Data(contentsOf: actionItemsURL) else { return [] }
        return (try? JSONDecoder().decode([ActionItem].self, from: data)) ?? []
    }

    public func saveActionItems(_ items: [ActionItem]) throws {
        try Self.encoder.encode(items).write(to: actionItemsURL, options: .atomic)
    }

    public func removePartials() {
        for url in [micPartialURL, systemPartialURL] {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("chunks.json"))
        }
    }

    public func updateMeta(_ change: (inout RecordingMeta) -> Void) {
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
    public static func scan(base: URL) -> [RecordingFolder] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { RecordingFolder(url: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.metaURL.path) }
    }
}

/// Builds transcript.md from raw segments, applying the speaker name mapping.
/// Used after transcription and whenever speakers are renamed.
public enum TranscriptWriter {
    public static func languageLabel(_ meta: RecordingMeta) -> String {
        guard meta.language == "auto" else { return meta.language }
        return meta.detectedLanguage.map { "auto (detected: \($0))" } ?? "auto"
    }

    /// Segments with display names applied, merged by speaker turn unless `merge` is false.
    public static func displaySegments(meta: RecordingMeta, rawSegments: [Segment], merge: Bool = true) -> [Segment] {
        let names = meta.speakerNames ?? [:]
        let renamed = rawSegments.filter { $0.droppedAsEcho != true }.map { s -> Segment in
            var c = s
            if let raw = s.speaker, let name = names[raw], !name.isEmpty { c.speaker = name }
            return c
        }
        return merge ? TranscriptFormatter.merge(renamed) : renamed
    }

    @discardableResult
    public static func write(folder: RecordingFolder, meta: RecordingMeta, rawSegments: [Segment]) throws -> String {
        let header = TranscriptFormatter.Header(
            title: meta.title, date: meta.date, durationSeconds: meta.durationSeconds,
            provider: meta.model ?? meta.provider ?? "unknown", language: languageLabel(meta),
            audioFiles: folder.audioURLs.map(\.lastPathComponent), tags: meta.tags ?? [])
        let markdown = TranscriptFormatter.markdown(header: header, merged: displaySegments(meta: meta, rawSegments: rawSegments),
                                                    bookmarks: meta.bookmarks ?? [])
        try markdown.write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
        return markdown
    }

    /// Distinct raw speaker labels in order of first appearance.
    public static func speakers(in rawSegments: [Segment]) -> [String] {
        var seen: [String] = []
        for s in rawSegments.sorted(by: { $0.start < $1.start }) where s.droppedAsEcho != true {
            if let sp = s.speaker, !seen.contains(sp) { seen.append(sp) }
        }
        return seen
    }
}

/// Why a change to a call could not be made.
public struct RecordingError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

/// Edits made from the library and by agents, the same way in both.
public extension RecordingFolder {
    /// Sets the title in meta.json and in the first line of transcript.md.
    /// Returns false when the title is empty; throws when meta.json can't be written.
    @discardableResult
    func rename(to newTitle: String) throws -> Bool {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        if var meta = loadMeta() {
            meta.title = title
            try saveMeta(meta)
        }
        if var text = try? String(contentsOf: transcriptURL, encoding: .utf8), text.hasPrefix("# ") {
            let firstLineEnd = text.firstIndex(of: "\n") ?? text.endIndex
            text.replaceSubrange(text.startIndex..<firstLineEnd, with: "# \(title)")
            try? text.write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
        return true
    }

    /// Replaces the tags and rewrites transcript.md, whose header lists them.
    func setTags(_ tags: [String]) {
        guard var meta = loadMeta() else { return }
        let clean = Tags.normalize(tags)
        meta.tags = clean.isEmpty ? nil : clean
        try? saveMeta(meta)
        if let raw = loadSegments() { _ = try? TranscriptWriter.write(folder: self, meta: meta, rawSegments: raw) }
    }

    /// Stores display names for raw speaker labels and regenerates transcript.md.
    func renameSpeakers(_ names: [String: String]) throws {
        guard var meta = loadMeta(), let raw = loadSegments() else {
            throw RecordingError(message: "This recording has no segments.json; re-transcribe it first.")
        }
        let clean = names.compactMapValues { v -> String? in
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }.filter { $0.key != $0.value }
        meta.speakerNames = clean.isEmpty ? nil : clean
        try saveMeta(meta)
        try TranscriptWriter.write(folder: self, meta: meta, rawSegments: raw)
    }
}
