import Foundation

/// A call in the recordings folder.
public struct CallEntry: Sendable {
    public let folder: RecordingFolder
    public let meta: RecordingMeta

    public init(folder: RecordingFolder, meta: RecordingMeta) {
        self.folder = folder
        self.meta = meta
    }

    /// The short id of the call, the same one chats cite it by.
    public var id: String { CallLibrary.id(for: folder) }
}

/// The calls of a recordings folder, read straight from disk.
public struct CallLibrary: Sendable {
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    public static func id(for folder: RecordingFolder) -> String {
        ChatPrompt.ref(forFolderName: folder.url.lastPathComponent)
    }

    /// Every call with a readable meta.json, the latest first.
    public func calls() -> [CallEntry] {
        RecordingFolder.scan(base: base)
            .compactMap { f in f.loadMeta().map { CallEntry(folder: f, meta: $0) } }
            .sorted { $0.meta.date > $1.meta.date }
    }

    /// The call folder at `path` when it is directly inside the recordings folder and has a
    /// meta.json; nil for any other path. Accepts `~` and file URLs.
    public func folder(atPath path: String) -> RecordingFolder? {
        var raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("file://"), let url = URL(string: raw) { raw = url.path }
        raw = (raw as NSString).expandingTildeInPath
        guard raw.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let root = base.standardizedFileURL.resolvingSymlinksInPath()
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().path == root.path, !name.hasPrefix(".") else { return nil }
        // Built from the base folder, so its key matches the folders the app scans.
        let folder = RecordingFolder(url: base.appendingPathComponent(name, isDirectory: true))
        return FileManager.default.fileExists(atPath: folder.metaURL.path) ? folder : nil
    }

    /// The call an agent refers to: by its id, its folder name or its folder path.
    /// Nil when none matches or the id is shared by several calls.
    public func resolve(_ reference: String) -> CallEntry? {
        let found = matches(reference)
        return found.count == 1 ? found[0] : nil
    }

    /// Every call `reference` can mean; more than one when ids collide.
    public func matches(_ reference: String) -> [CallEntry] {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return [] }
        if ref.contains("/") || ref.hasPrefix("~") {
            guard let folder = folder(atPath: ref), let meta = folder.loadMeta() else { return [] }
            return [CallEntry(folder: folder, meta: meta)]
        }
        let all = calls()
        let byID = all.filter { $0.id == ref.lowercased() }
        return byID.isEmpty ? all.filter { $0.folder.url.lastPathComponent == ref } : byID
    }
}

/// Which calls to list or search.
public struct CallFilter: Equatable, Sendable {
    /// Part of the title, a tag, the source or the calendar event.
    public var query: String?
    public var tag: String?
    public var source: String?
    public var from: Date?
    public var to: Date?

    public init(query: String? = nil, tag: String? = nil, source: String? = nil, from: Date? = nil, to: Date? = nil) {
        self.query = query
        self.tag = tag
        self.source = source
        self.from = from
        self.to = to
    }

    public func matches(_ meta: RecordingMeta) -> Bool {
        if let from, meta.date < from { return false }
        if let to, meta.date > to { return false }
        if let tag, !Tags.contains(meta.tags ?? [], tag) { return false }
        if let source {
            let names = [meta.source, meta.sourceApp].compactMap { $0 }
            guard names.contains(where: { Self.fold($0) == Self.fold(source) }) else { return false }
        }
        if let query {
            let q = Self.fold(query)
            let fields = [meta.title, meta.source, meta.sourceApp, meta.calendarEvent?.title].compactMap { $0 } + (meta.tags ?? [])
            guard fields.contains(where: { Self.fold($0).contains(q) }) else { return false }
        }
        return true
    }

    /// Case and accents ignored.
    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

public enum CallDates {
    /// A date written as `2026-09-23` (the start of that day, or its end with `endOfDay`)
    /// or as ISO 8601, with or without the time zone (local time without).
    public static func parse(_ text: String, endOfDay: Bool = false, calendar: Calendar = .current) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        if s.count == 10 {
            local.dateFormat = "yyyy-MM-dd"
            guard let day = local.date(from: s) else { return nil }
            guard endOfDay else { return day }
            return (calendar.date(byAdding: .day, value: 1, to: day) ?? day).addingTimeInterval(-0.001)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: s) { return d }
        }
        return nil
    }

    /// `2026-09-23T14:30:00+02:00`, in the time zone of `calendar`.
    public static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = calendar.timeZone
        return iso.string(from: date)
    }
}

/// A slice of a list, and where the next one starts.
public struct ListPage<Item> {
    public var items: [Item]
    public var total: Int
    public var offset: Int
    /// Nil on the last page.
    public var nextOffset: Int?

    public init(_ all: [Item], offset: Int, limit: Int) {
        let start = min(max(0, offset), all.count)
        let end = min(all.count, start + max(0, limit))
        items = Array(all[start..<end])
        total = all.count
        self.offset = start
        nextOffset = end < all.count ? end : nil
    }
}

/// A call's transcript.md, read in pages.
public struct CallTranscript: Sendable {
    public let path: String
    public let markdown: String
    /// The speaker turns, as written in the file.
    public let turns: [TranscriptBlock]

    public init(markdown: String, path: String) {
        self.markdown = markdown
        self.path = path
        turns = TranscriptFormatter.parseBlocks(markdown)
    }

    public static func load(_ folder: RecordingFolder) -> CallTranscript? {
        guard let text = try? String(contentsOf: folder.transcriptURL, encoding: .utf8) else { return nil }
        return CallTranscript(markdown: text, path: folder.transcriptURL.path)
    }

    public var characterCount: Int { markdown.count }

    /// `[00:01:02] Anna: text`
    public static func line(_ turn: TranscriptBlock) -> String {
        "[\(TranscriptFormatter.timestamp(turn.start))] \(turn.speaker): \(turn.text)"
    }

    /// Turns `offset..<offset+limit`, one per line.
    public func turnPage(offset: Int, limit: Int) -> ListPage<String> {
        let page = ListPage(turns, offset: offset, limit: limit)
        return ListPage(page.items.map(Self.line), total: page.total, offset: page.offset, nextOffset: page.nextOffset)
    }

    /// Characters `offset..<offset+limit` of the file, as is.
    public func characterPage(offset: Int, limit: Int) -> ListPage<Character> {
        ListPage(Array(markdown), offset: offset, limit: limit)
    }
}

extension ListPage {
    init(_ items: [Item], total: Int, offset: Int, nextOffset: Int?) {
        self.items = items
        self.total = total
        self.offset = offset
        self.nextOffset = nextOffset
    }
}

/// A transcript turn that contains the searched text.
public struct TranscriptMatch: Equatable, Sendable {
    public var time: Double
    public var speaker: String
    public var snippet: String

    public init(time: Double, speaker: String, snippet: String) {
        self.time = time
        self.speaker = speaker
        self.snippet = snippet
    }
}

/// Full-text search in transcripts, ignoring case and accents.
public enum TranscriptSearch {
    public static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Every turn that contains `query`, with the text around its first occurrence.
    public static func matches(in turns: [TranscriptBlock], query: String, radius: Int = 80) -> [TranscriptMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return turns.compactMap { turn in
            guard let range = turn.text.range(of: q, options: options) else { return nil }
            return TranscriptMatch(time: turn.start, speaker: turn.speaker, snippet: snippet(turn.text, around: range, radius: radius))
        }
    }

    /// About `radius` characters on each side of `range`, cut between words, with `…`
    /// where the text goes on.
    public static func snippet(_ text: String, around range: Range<String.Index>, radius: Int = 80) -> String {
        var lower = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        var upper = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        if lower > text.startIndex, let space = text[lower..<range.lowerBound].firstIndex(where: \.isWhitespace) {
            lower = text.index(after: space)
        }
        if upper < text.endIndex, let space = text[range.upperBound..<upper].lastIndex(where: \.isWhitespace) {
            upper = space
        }
        let middle = text[lower..<upper].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (lower > text.startIndex ? "…" : "") + middle + (upper < text.endIndex ? "…" : "")
    }
}
