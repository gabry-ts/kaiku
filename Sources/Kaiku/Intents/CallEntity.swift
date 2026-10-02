import AppIntents
import KaikuCore

/// A call in the library, as Shortcuts and Siri see it. Its id is the call folder's key.
struct CallEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Call"
    static let defaultQuery = CallEntityQuery()

    var id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Date")
    var date: Date

    @Property(title: "Tags")
    var tags: [String]

    @Property(title: "Source")
    var source: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(date.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    init(_ call: CallEntry) {
        id = call.folder.key
        title = call.meta.title
        date = call.meta.date
        tags = call.meta.tags ?? []
        source = call.meta.source ?? call.meta.sourceApp
    }

    /// The folder of the call; nil when it is no longer in the recordings folder.
    var folder: RecordingFolder? {
        let folder = RecordingFolder(url: URL(fileURLWithPath: id, isDirectory: true))
        return FileManager.default.fileExists(atPath: folder.metaURL.path) ? folder : nil
    }
}

struct CallEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CallEntity] {
        CallLibrary(base: AppSettings.baseFolder).calls()
            .filter { identifiers.contains($0.folder.key) }
            .map(CallEntity.init)
    }

    func entities(matching string: String) async throws -> [CallEntity] {
        CallSearch.find(base: AppSettings.baseFolder, text: string).map(CallEntity.init)
    }

    func suggestedEntities() async throws -> [CallEntity] {
        CallLibrary(base: AppSettings.baseFolder).calls().prefix(10).map(CallEntity.init)
    }
}

/// Looking calls up for intents.
enum CallSearch {
    /// Calls with the tag and source given whose title, tags, source or transcript contain
    /// `text`, the latest first.
    static func find(base: URL, text: String? = nil, tag: String? = nil, source: String? = nil) -> [CallEntry] {
        let query = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scope = CallFilter(tag: tag, source: source)
        let byText = CallFilter(query: query)
        return CallLibrary(base: base).calls().filter { call in
            guard scope.matches(call.meta) else { return false }
            if query.isEmpty || byText.matches(call.meta) { return true }
            return CallTranscript.load(call.folder)?.markdown.range(of: query, options: TranscriptSearch.options) != nil
        }
    }

    /// The most recent call, if any.
    static func last(base: URL) -> CallEntry? {
        CallLibrary(base: base).calls().first
    }
}
