import Foundation

/// The tools Kaiku's MCP server offers: reading calls always, changing them only when
/// the user allowed it in Settings.
public struct KaikuToolSet: MCPToolSet {
    public var library: CallLibrary
    /// Read on every request, so the Settings switch applies without restarting the server.
    public var allowEdits: () -> Bool
    /// Asks the app for work it does itself (transcribing, summarizing).
    public var openInApp: (AgentRequest) throws -> Void
    /// Called after a call was changed on disk.
    public var changed: () -> Void

    /// Embeds the query of semantic_search.
    public var embedder: TextEmbedder

    public init(library: CallLibrary, allowEdits: @escaping () -> Bool,
                openInApp: @escaping (AgentRequest) throws -> Void = { _ in }, changed: @escaping () -> Void = {},
                embedder: TextEmbedder = NLSentenceEmbedder()) {
        self.embedder = embedder
        self.library = library
        self.allowEdits = allowEdits
        self.openInApp = openInApp
        self.changed = changed
    }

    public static let instructions = """
    Kaiku records and transcribes the user's calls on this Mac. Each call has an id like "c3fa9b2" (the same ids Kaiku's chat cites) and a folder with transcript.md, summary.md when there is one, and meta.json. Use list_calls or search_transcripts to find calls, then read_transcript or read_summary. Transcript lines start with their time as [HH:MM:SS]; cite calls as [id HH:MM:SS]. You can also read transcript.md directly at the path the tools give.
    """

    public static let readToolNames = ["list_calls", "get_call", "read_transcript", "read_summary", "search_transcripts", "semantic_search"]
    public static let editToolNames = ["rename_call", "set_tags", "rename_speaker", "transcribe_again", "summarize_again"]

    public func tools() -> [MCPTool] {
        Self.readTools + (allowEdits() ? Self.editTools : [])
    }

    public func call(_ name: String, arguments: [String: JSONValue]) throws -> MCPToolResult {
        let args = MCPArguments(arguments)
        if Self.editToolNames.contains(name) {
            guard allowEdits() else {
                return .error("Changing calls is turned off. The user can allow it in Kaiku > Settings > Integrations > Agents (MCP) > Allow agents to edit calls.")
            }
        }
        switch name {
        case "list_calls": return try listCalls(args)
        case "get_call": return try getCall(args)
        case "read_transcript": return try readTranscript(args)
        case "read_summary": return try readSummary(args)
        case "search_transcripts": return try searchTranscripts(args)
        case "semantic_search": return try semanticSearch(args)
        case "rename_call": return try renameCall(args)
        case "set_tags": return try setTags(args)
        case "rename_speaker": return try renameSpeaker(args)
        case "transcribe_again": return try transcribeAgain(args)
        case "summarize_again": return try summarizeAgain(args)
        default: throw MCPError.invalidParams("Unknown tool: \(name)")
        }
    }

    // MARK: Reading

    private func callFilter(_ args: MCPArguments) throws -> CallFilter {
        func date(_ key: String, endOfDay: Bool) throws -> Date? {
            guard let text = try args.string(key) else { return nil }
            guard let d = CallDates.parse(text, endOfDay: endOfDay) else {
                throw MCPError.invalidParams("\(key) must be a date like 2026-09-23 or 2026-09-23T14:30:00+02:00")
            }
            return d
        }
        return CallFilter(query: try args.string("query"), tag: try args.string("tag"), source: try args.string("source"),
                          from: try date("from", endOfDay: false), to: try date("to", endOfDay: true))
    }

    private func listCalls(_ args: MCPArguments) throws -> MCPToolResult {
        let filter = try callFilter(args)
        let limit = try args.int("limit", default: 50, in: 1...500)
        let offset = try args.int("offset", default: 0, in: 0...Int.max)
        let page = ListPage(library.calls().filter { filter.matches($0.meta) }, offset: offset, limit: limit)
        var result: [String: JSONValue] = [
            "total": .int(page.total), "offset": .int(page.offset), "calls": .array(page.items.map(Self.listing)),
        ]
        if let next = page.nextOffset { result["nextOffset"] = .int(next) }
        return MCPToolResult(text: JSONValue.object(result).prettyText())
    }

    static func listing(_ c: CallEntry) -> JSONValue {
        [
            "id": .string(c.id),
            "title": .string(c.meta.title),
            "date": .string(CallDates.format(c.meta.date)),
            "duration": .string(TranscriptFormatter.timestamp(c.meta.durationSeconds)),
            "tags": .array((c.meta.tags ?? []).map(JSONValue.string)),
            "source": .optional(c.meta.source),
            "status": .string(c.meta.status.rawValue),
            "hasTranscript": .bool(c.folder.hasTranscript),
            "hasSummary": .bool(c.folder.hasSummary),
            "folder": .string(c.folder.url.path),
        ]
    }

    private func entry(_ args: MCPArguments) throws -> CallEntry? {
        library.resolve(try args.requiredString("id"))
    }

    private func notFound(_ args: MCPArguments) -> MCPToolResult {
        let id = (try? args.string("id")) ?? ""
        if library.matches(id).count > 1 {
            return .error("The id \(id) matches more than one call; pass the call folder path instead (see list_calls).")
        }
        return .error("No call with id \(id) in the recordings folder. Use list_calls to find its id.")
    }

    private func getCall(_ args: MCPArguments) throws -> MCPToolResult {
        guard let c = try entry(args) else { return notFound(args) }
        let m = c.meta, f = c.folder
        var o = Self.listing(c).objectValue ?? [:]
        o["durationSeconds"] = .double(m.durationSeconds)
        o["sourceApp"] = .optional(m.sourceApp)
        o["error"] = .optional(m.error)
        o["language"] = .string(TranscriptWriter.languageLabel(m))
        o["provider"] = .optional(m.provider)
        o["model"] = .optional(m.model)
        o["summaryModel"] = .optional(m.summaryModel)
        o["bookmarks"] = .array((m.bookmarks ?? []).sorted { $0.time < $1.time }.map { b -> JSONValue in
            ["time": .string(TranscriptFormatter.timestamp(b.time)), "seconds": .double(b.time), "label": .string(b.label)]
        })
        o["speakers"] = .array(speakers(c).map { s -> JSONValue in ["label": .string(s.label), "name": .string(s.name)] })
        if let event = m.calendarEvent {
            o["calendarEvent"] = [
                "title": .string(event.title),
                "start": .string(CallDates.format(event.start)),
                "end": .string(CallDates.format(event.end)),
                "attendees": .array(event.attendees.compactMap { a -> JSONValue? in (a.name ?? a.email).map(JSONValue.string) }),
            ]
        }
        let fm = FileManager.default
        func path(_ url: URL) -> JSONValue { fm.fileExists(atPath: url.path) ? .string(url.path) : .null }
        o["files"] = [
            "transcript": path(f.transcriptURL),
            "summary": path(f.summaryURL),
            "segments": path(f.segmentsURL),
            "meta": .string(f.metaURL.path),
            "audio": .array(f.allAudioURLs.map { JSONValue.string($0.path) }),
        ]
        return MCPToolResult(text: JSONValue.object(o).prettyText())
    }

    /// Raw labels with their display names: from segments.json, else from transcript.md.
    private func speakers(_ c: CallEntry) -> [(label: String, name: String)] {
        if let raw = c.folder.loadSegments() {
            let names = c.meta.speakerNames ?? [:]
            return TranscriptWriter.speakers(in: raw).map { (label: $0, name: names[$0] ?? $0) }
        }
        var seen: [String] = []
        for t in CallTranscript.load(c.folder)?.turns ?? [] where !seen.contains(t.speaker) { seen.append(t.speaker) }
        return seen.map { (label: $0, name: $0) }
    }

    private static func noTranscript(_ c: CallEntry) -> MCPToolResult {
        .error("\"\(c.meta.title)\" has no transcript yet (status: \(c.meta.status.rawValue)).")
    }

    private func readTranscript(_ args: MCPArguments) throws -> MCPToolResult {
        let unit = try args.choice("unit", ["turns", "characters"], default: "turns")
        let offset = try args.int("offset", default: 0, in: 0...Int.max)
        let limit: Int
        if unit == "turns" {
            limit = try args.int("limit", default: 200, in: 1...2000)
        } else {
            limit = try args.int("limit", default: 40_000, in: 1...400_000)
        }
        guard let c = try entry(args) else { return notFound(args) }
        guard let t = CallTranscript.load(c.folder) else { return Self.noTranscript(c) }
        let bytes = RecordingFolder.fileSize(c.folder.transcriptURL)
        var lines = [
            "Call \(c.id): \"\(c.meta.title)\", \(ChatPrompt.dateText(c.meta.date)), \(TranscriptFormatter.timestamp(c.meta.durationSeconds))",
            "File: \(t.path) (\(t.characterCount) characters, \(bytes) bytes, \(t.turns.count) turns)",
        ]
        let body: String
        if unit == "turns" {
            let page = t.turnPage(offset: offset, limit: limit)
            lines.append(page.items.isEmpty ? "No turns from offset \(page.offset) (there are \(page.total))."
                : "Turns \(page.offset + 1)–\(page.offset + page.items.count) of \(page.total)."
                    + (page.nextOffset.map { " More: offset \($0)." } ?? ""))
            body = page.items.joined(separator: "\n\n")
        } else {
            let page = t.characterPage(offset: offset, limit: limit)
            lines.append("Characters \(page.offset)–\(page.offset + page.items.count) of \(page.total)."
                         + (page.nextOffset.map { " More: offset \($0)." } ?? ""))
            body = String(page.items)
        }
        return MCPToolResult(text: lines.joined(separator: "\n") + "\n\n" + body)
    }

    private func readSummary(_ args: MCPArguments) throws -> MCPToolResult {
        guard let c = try entry(args) else { return notFound(args) }
        guard let summary = c.folder.summary else {
            return .error("\"\(c.meta.title)\" has no summary." + (allowEdits() && c.folder.hasTranscript ? " summarize_again can write one." : ""))
        }
        let by = c.meta.summaryModel.map { ", written by \($0)" } ?? ""
        return MCPToolResult(text: "Summary of call \(c.id) \"\(c.meta.title)\"\(by)\nFile: \(c.folder.summaryURL.path)\n\n"
                             + summary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func searchTranscripts(_ args: MCPArguments) throws -> MCPToolResult {
        let query = try args.requiredString("query")
        let filter = try callFilter(args.removing("query"))
        let limit = try args.int("limit", default: 20, in: 1...200)
        let offset = try args.int("offset", default: 0, in: 0...Int.max)
        var results: [JSONValue] = []
        var found = 0
        var more = false
        search: for c in library.calls() where filter.matches(c.meta) {
            guard let t = CallTranscript.load(c.folder) else { continue }
            for m in TranscriptSearch.matches(in: t.turns, query: query) {
                defer { found += 1 }
                guard found >= offset else { continue }
                guard results.count < limit else { more = true; break search }
                results.append([
                    "id": .string(c.id), "title": .string(c.meta.title), "date": .string(CallDates.format(c.meta.date)),
                    "time": .string(TranscriptFormatter.timestamp(m.time)), "speaker": .string(m.speaker),
                    "snippet": .string(m.snippet),
                ])
            }
        }
        var o: [String: JSONValue] = ["query": .string(query), "offset": .int(offset), "matches": .array(results)]
        if more { o["nextOffset"] = .int(offset + results.count) }
        return MCPToolResult(text: JSONValue.object(o).prettyText())
    }

    /// Passages closest in meaning to the query, from the indexes the app keeps in the call folders.
    private func semanticSearch(_ args: MCPArguments) throws -> MCPToolResult {
        let query = try args.requiredString("query")
        let filter = try callFilter(args.removing("query"))
        let limit = try args.int("limit", default: 10, in: 1...100)
        let calls = library.calls().filter { filter.matches($0.meta) }
        let indexed = calls.compactMap { c in c.folder.loadSemanticIndex().map { (call: c, index: $0) } }
        var vectors: [String: [Float]] = [:]
        for language in Set(indexed.map(\.index.language)) {
            if let v = embedder.embed(query, language: language) { vectors[language] = v }
        }
        let byID = Dictionary(indexed.map { ($0.call.id, $0.call) }, uniquingKeysWith: { a, _ in a })
        let matches = SemanticRanker.rank(queries: vectors, indexes: indexed.map { (callID: $0.call.id, index: $0.index) }, limit: limit)
        var o: [String: JSONValue] = ["query": .string(query), "matches": .array(matches.compactMap { m -> JSONValue? in
            guard let c = byID[m.callID] else { return nil }
            return [
                "id": .string(c.id), "title": .string(c.meta.title), "date": .string(CallDates.format(c.meta.date)),
                "time": .string(TranscriptFormatter.timestamp(m.passage.start)), "speaker": .optional(m.passage.speaker),
                "text": .string(m.passage.text), "score": .double(Double(m.score)),
            ]
        })]
        let missing = calls.count - indexed.count
        if missing > 0 {
            o["note"] = .string("\(missing) of \(calls.count) calls are not searched by meaning yet: Kaiku indexes them in the background once Smart search was turned on in its Library. search_transcripts finds exact words in all of them.")
        }
        return MCPToolResult(text: JSONValue.object(o).prettyText())
    }

    // MARK: Editing

    /// Calls being recorded or transcribed are left alone.
    private func editable(_ c: CallEntry) -> MCPToolResult? {
        switch c.meta.status {
        case .recording, .paused: return .error("\"\(c.meta.title)\" is being recorded; try again when it ends.")
        case .transcribing: return .error("\"\(c.meta.title)\" is being transcribed; try again when it's done.")
        case .done, .error, .recovered: return nil
        }
    }

    private func renameCall(_ args: MCPArguments) throws -> MCPToolResult {
        let title = try args.requiredString("title")
        guard let c = try entry(args) else { return notFound(args) }
        if let busy = editable(c) { return busy }
        do {
            try c.folder.rename(to: title)
        } catch {
            return .error("Couldn't rename \"\(c.meta.title)\": \(error.localizedDescription)")
        }
        changed()
        return MCPToolResult(text: "Renamed call \(c.id) to \"\(title)\".")
    }

    private func setTags(_ args: MCPArguments) throws -> MCPToolResult {
        let replace = try args.strings("tags")
        let add = try args.strings("add") ?? []
        let remove = try args.strings("remove") ?? []
        guard replace != nil || !add.isEmpty || !remove.isEmpty else {
            throw MCPError.invalidParams("Give tags (to replace them all), add or remove")
        }
        guard let c = try entry(args) else { return notFound(args) }
        if let busy = editable(c) { return busy }
        let tags = Self.tags(current: c.meta.tags ?? [], replace: replace, add: add, remove: remove)
        c.folder.setTags(tags)
        changed()
        return MCPToolResult(text: "Tags of call \(c.id): " + (tags.isEmpty ? "none" : tags.joined(separator: ", ")) + ".")
    }

    /// `replace` (or the current tags), plus `add`, minus `remove`; case-insensitive.
    static func tags(current: [String], replace: [String]?, add: [String], remove: [String]) -> [String] {
        let removed = Set(remove.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return Tags.normalize((replace ?? current) + add).filter { !removed.contains($0.lowercased()) }
    }

    private func renameSpeaker(_ args: MCPArguments) throws -> MCPToolResult {
        let speaker = try args.requiredString("speaker")
        guard let name = try args.rawString("name") else { throw MCPError.invalidParams("name is required") }
        guard let c = try entry(args) else { return notFound(args) }
        if let busy = editable(c) { return busy }
        guard let raw = c.folder.loadSegments() else {
            return .error("\"\(c.meta.title)\" has no segments.json, so its speakers can't be renamed; transcribe it again first.")
        }
        var names = c.meta.speakerNames ?? [:]
        guard let label = Self.speakerLabel(speaker, labels: TranscriptWriter.speakers(in: raw), names: names) else {
            let known = TranscriptWriter.speakers(in: raw).map { label in names[label].map { "\($0) (\(label))" } ?? label }
            return .error("No speaker \"\(speaker)\" in this call. Speakers: " + known.joined(separator: ", ") + ".")
        }
        names[label] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try c.folder.renameSpeakers(names)
        } catch {
            return .error(error.localizedDescription)
        }
        changed()
        let shown = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return MCPToolResult(text: shown.isEmpty ? "\(label) of call \(c.id) has its original name again; transcript.md was rewritten."
                             : "\(label) of call \(c.id) is now \"\(shown)\"; transcript.md was rewritten.")
    }

    /// The raw label meant by `speaker`: a raw label, or the name shown for one.
    static func speakerLabel(_ speaker: String, labels: [String], names: [String: String]) -> String? {
        if let exact = labels.first(where: { $0 == speaker }) { return exact }
        let folded = CallFilter.fold(speaker)
        return labels.first { CallFilter.fold($0) == folded }
            ?? labels.first { label in names[label].map { name in CallFilter.fold(name) == folded } ?? false }
    }

    private func transcribeAgain(_ args: MCPArguments) throws -> MCPToolResult {
        guard let c = try entry(args) else { return notFound(args) }
        if let busy = editable(c) { return busy }
        let fm = FileManager.default
        guard fm.fileExists(atPath: c.folder.micURL.path) || fm.fileExists(atPath: c.folder.systemURL.path) else {
            return .error("\"\(c.meta.title)\" has no audio left to transcribe.")
        }
        return ask(.transcribe(folder: c.folder.url.path), c,
                   done: "Asked Kaiku to transcribe \"\(c.meta.title)\" again with the provider chosen in its Settings. Check get_call: status is \"transcribing\" while it works and \"done\" when finished.")
    }

    private func summarizeAgain(_ args: MCPArguments) throws -> MCPToolResult {
        guard let c = try entry(args) else { return notFound(args) }
        if let busy = editable(c) { return busy }
        guard c.folder.hasTranscript else { return Self.noTranscript(c) }
        return ask(.summarize(folder: c.folder.url.path), c,
                   done: "Asked Kaiku to write a new summary of \"\(c.meta.title)\" with the provider chosen in its Settings. Check get_call (hasSummary) and read it with read_summary in a minute or two.")
    }

    private func ask(_ request: AgentRequest, _ c: CallEntry, done: String) -> MCPToolResult {
        do {
            try openInApp(request)
            return MCPToolResult(text: done)
        } catch {
            return .error("Couldn't reach the Kaiku app: \(error.localizedDescription)")
        }
    }

    // MARK: Schemas

    private static let id: JSONValue = ["type": "string", "description": "Call id from list_calls (e.g. c3fa9b2), or the call folder path."]

    private static let filterProperties: [String: JSONValue] = [
        "tag": ["type": "string", "description": "Only calls with this tag."],
        "source": ["type": "string", "description": "Only calls from this source, e.g. Zoom, Google Meet, WhatsApp, Manual, Imported."],
        "from": ["type": "string", "description": "Calls on or after this date: 2026-09-23 or ISO 8601."],
        "to": ["type": "string", "description": "Calls on or before this date (the whole day when only a date): 2026-09-30 or ISO 8601."],
    ]

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string))]
    }

    private static func merging(_ a: [String: JSONValue], _ b: [String: JSONValue]) -> [String: JSONValue] {
        a.merging(b) { _, new in new }
    }

    static let readTools: [MCPTool] = [
        MCPTool(name: "list_calls",
                description: "List the user's recorded calls, latest first, with id, title, date, duration, tags, source, status and whether there is a transcript and summary.",
                inputSchema: schema(merging(filterProperties, [
                    "query": ["type": "string", "description": "Text in the title, tags, source or calendar event (case and accents ignored)."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Calls to return, 50 by default."],
                    "offset": ["type": "integer", "minimum": 0, "description": "Calls to skip, for the next page."],
                ]))),
        MCPTool(name: "get_call",
                description: "Details of a call: date, duration, status, language, provider, tags, source, speakers (raw label and name), bookmarks (time and label), calendar event and the paths of transcript.md, summary.md and the audio files.",
                inputSchema: schema(["id": id], required: ["id"])),
        MCPTool(name: "read_transcript",
                description: "Read a call's transcript, a page at a time: speaker turns as \"[HH:MM:SS] Speaker: text\", or the raw transcript.md by characters. Also gives the path and size of transcript.md, which can be read directly.",
                inputSchema: schema([
                    "id": id,
                    "unit": ["type": "string", "enum": ["turns", "characters"], "description": "Page by speaker turns (default) or by characters of transcript.md."],
                    "offset": ["type": "integer", "minimum": 0, "description": "First turn or character, from 0."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 400_000, "description": "Turns (default 200, at most 2000) or characters (default 40000, at most 400000) to return."],
                ], required: ["id"])),
        MCPTool(name: "read_summary",
                description: "Read a call's summary (summary.md), when one was written.",
                inputSchema: schema(["id": id], required: ["id"])),
        MCPTool(name: "search_transcripts",
                description: "Search the text of all transcripts (case and accents ignored), latest calls first. Returns each matching turn with call id, title, time, speaker and a snippet.",
                inputSchema: schema(merging(filterProperties, [
                    "query": ["type": "string", "description": "Words or phrase to find."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Matches to return, 20 by default."],
                    "offset": ["type": "integer", "minimum": 0, "description": "Matches to skip, for the next page."],
                ]), required: ["query"])),
        MCPTool(name: "semantic_search",
                description: "Find the passages of the calls closest in meaning to a question or topic, even when the words differ. Returns the best passages with call id, title, time, speaker, text and score. Only calls already indexed by Kaiku are searched.",
                inputSchema: schema(merging(filterProperties, [
                    "query": ["type": "string", "description": "A question or topic, in natural language."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Passages to return, 10 by default."],
                ]), required: ["query"])),
    ]

    static let editTools: [MCPTool] = [
        MCPTool(name: "rename_call",
                description: "Change a call's title (meta.json and the first line of transcript.md).",
                inputSchema: schema(["id": id, "title": ["type": "string", "description": "The new title."]], required: ["id", "title"])),
        MCPTool(name: "set_tags",
                description: "Change a call's tags: replace them all with tags, and/or add and remove some.",
                inputSchema: schema([
                    "id": id,
                    "tags": ["type": "array", "items": ["type": "string"], "description": "The new tags, replacing the current ones."],
                    "add": ["type": "array", "items": ["type": "string"], "description": "Tags to add."],
                    "remove": ["type": "array", "items": ["type": "string"], "description": "Tags to remove."],
                ], required: ["id"])),
        MCPTool(name: "rename_speaker",
                description: "Give a speaker of a call a name, e.g. \"Speaker 2\" -> \"Anna\"; transcript.md is rewritten with it. An empty name restores the original label. See get_call for the speakers.",
                inputSchema: schema([
                    "id": id,
                    "speaker": ["type": "string", "description": "The raw label (e.g. Speaker 2) or the name shown now."],
                    "name": ["type": "string", "description": "The name to show; empty to restore the label."],
                ], required: ["id", "speaker", "name"])),
        MCPTool(name: "transcribe_again",
                description: "Ask the Kaiku app to transcribe a call again with the provider chosen in its Settings, replacing the transcript. Runs in the background; the app opens if needed.",
                inputSchema: schema(["id": id], required: ["id"])),
        MCPTool(name: "summarize_again",
                description: "Ask the Kaiku app to write the call's summary again with the summary provider chosen in its Settings. Runs in the background; the app opens if needed.",
                inputSchema: schema(["id": id], required: ["id"])),
    ]
}

extension MCPArguments {
    func removing(_ key: String) -> MCPArguments {
        var v = values
        v[key] = nil
        return MCPArguments(v)
    }
}
