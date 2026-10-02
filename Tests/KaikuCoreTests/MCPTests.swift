import XCTest
@testable import KaikuCore

final class MCPTests: XCTestCase {
    /// Echoes its arguments; "fail" fails, "strict" needs a number.
    private struct FakeTools: MCPToolSet {
        func tools() -> [MCPTool] {
            [MCPTool(name: "echo", description: "Echo", inputSchema: ["type": "object"])]
        }

        func call(_ name: String, arguments: [String: JSONValue]) throws -> MCPToolResult {
            switch name {
            case "echo": return MCPToolResult(text: JSONValue.object(arguments).compactText())
            case "fail": return .error("It broke")
            case "strict":
                let n = try MCPArguments(arguments).int("n", default: 0, in: 0...9)
                return MCPToolResult(text: String(n))
            default: throw MCPError.invalidParams("Unknown tool: \(name)")
            }
        }
    }

    private let server = MCPServer(name: "kaiku", version: "1.2.3", instructions: "Hi", toolSet: FakeTools())

    private func reply(_ line: String) throws -> JSONValue? {
        guard let text = server.handle(line: line) else { return nil }
        XCTAssertFalse(text.contains("\n"), "replies are one line")
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: JSON-RPC

    func testInitializeEchoesASupportedVersionOrOffersTheLatest() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(r?["id"], .int(1))
        XCTAssertEqual(r?["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(r?["result"]?["serverInfo"]?["name"], "kaiku")
        XCTAssertEqual(r?["result"]?["serverInfo"]?["version"], "1.2.3")
        XCTAssertNotNil(r?["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(r?["result"]?["instructions"], "Hi")

        let other = try reply(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual(other?["id"], "a")
        XCTAssertEqual(other?["result"]?["protocolVersion"], .string(MCPServer.latestProtocolVersion))
    }

    func testNotificationsAndResponsesGetNoReply() throws {
        XCTAssertNil(try reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(try reply(#"{"jsonrpc":"2.0","method":"notifications/unknown","params":{}}"#))
        XCTAssertNil(try reply(#"{"jsonrpc":"2.0","id":5,"result":{}}"#))
        XCTAssertNil(try reply("   "))
    }

    func testPingListAndErrors() throws {
        XCTAssertEqual(try reply(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)?["result"], .object([:]))
        let list = try reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)
        XCTAssertEqual(list?["result"]?["tools"]?.arrayValue?.first?["name"], "echo")

        XCTAssertEqual(try reply(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)?["error"]?["code"], .int(-32601))
        XCTAssertEqual(try reply(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#)?["error"]?["code"], .int(-32602))
        XCTAssertEqual(try reply(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}"#)?["error"]?["code"], .int(-32602))
        XCTAssertEqual(try reply(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"echo","arguments":[1]}}"#)?["error"]?["code"], .int(-32602))
        XCTAssertEqual(try reply(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"strict","arguments":{"n":"x"}}}"#)?["error"]?["code"], .int(-32602))
        let parse = try reply("{not json")
        XCTAssertEqual(parse?["error"]?["code"], .int(-32700))
        XCTAssertEqual(parse?["id"], .null)
    }

    func testToolCallResults() throws {
        let ok = try reply(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"echo","arguments":{"a":"b/c"}}}"#)
        XCTAssertEqual(ok?["result"]?["content"]?.arrayValue?.first?["type"], "text")
        XCTAssertEqual(ok?["result"]?["content"]?.arrayValue?.first?["text"], #"{"a":"b/c"}"#)
        XCTAssertNil(ok?["result"]?["isError"])

        let failed = try reply(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"fail"}}"#)
        XCTAssertEqual(failed?["result"]?["isError"], true)
        XCTAssertEqual(failed?["result"]?["content"]?.arrayValue?.first?["text"], "It broke")
    }

    func testArguments() throws {
        let args = MCPArguments(["s": "  hi ", "blank": " ", "n": .double(3), "list": "one", "bad": 1])
        XCTAssertEqual(try args.string("s"), "hi")
        XCTAssertNil(try args.string("blank"))
        XCTAssertEqual(try args.int("n", default: 0, in: 0...5), 3)
        XCTAssertEqual(try args.int("missing", default: 7, in: 0...9), 7)
        XCTAssertThrowsError(try args.int("n", default: 0, in: 0...2))
        XCTAssertEqual(try args.strings("list"), ["one"])
        XCTAssertThrowsError(try args.string("bad"))
        XCTAssertThrowsError(try args.requiredString("blank"))
    }

    // MARK: Pages and search

    func testPages() {
        let page = ListPage(Array(0..<10), offset: 4, limit: 3)
        XCTAssertEqual(page.items, [4, 5, 6])
        XCTAssertEqual(page.total, 10)
        XCTAssertEqual(page.nextOffset, 7)
        let last = ListPage(Array(0..<10), offset: 8, limit: 5)
        XCTAssertEqual(last.items, [8, 9])
        XCTAssertNil(last.nextOffset)
        let past = ListPage(Array(0..<3), offset: 10, limit: 5)
        XCTAssertEqual(past.items, [])
        XCTAssertEqual(past.offset, 3)
    }

    private let markdown = """
    # Weekly sync

    - **Date:** 2026-09-23 14:30

    ---

    **[00:00:01] Me:** Hello everyone.

    🔖 [00:00:02] Bookmark: start

    **[00:00:05] Anna:** Il perché della migrazione è la velocità.

    **[00:01:10] Me:** Ok, then the release moves to November.

    """

    func testTranscriptPagesByTurnsAndCharacters() {
        let t = CallTranscript(markdown: markdown, path: "/x/transcript.md")
        XCTAssertEqual(t.turns.count, 3)
        let page = t.turnPage(offset: 1, limit: 1)
        XCTAssertEqual(page.items, ["[00:00:05] Anna: Il perché della migrazione è la velocità."])
        XCTAssertEqual(page.nextOffset, 2)
        let chars = t.characterPage(offset: 2, limit: 6)
        XCTAssertEqual(String(chars.items), "Weekly")
        XCTAssertEqual(chars.total, markdown.count)
    }

    func testSearchIgnoresCaseAndAccentsAndCutsSnippetsOnWords() {
        let t = CallTranscript(markdown: markdown, path: "/x/transcript.md")
        let hits = TranscriptSearch.matches(in: t.turns, query: "PERCHE")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.time, 5)
        XCTAssertEqual(hits.first?.speaker, "Anna")

        let text = "one two three four five six seven eight nine ten"
        let range = text.range(of: "five")!
        XCTAssertEqual(TranscriptSearch.snippet(text, around: range, radius: 6), "…four five six…")
        XCTAssertEqual(TranscriptSearch.snippet("just five", around: "just five".range(of: "five")!, radius: 20), "just five")
        XCTAssertTrue(TranscriptSearch.matches(in: t.turns, query: "  ").isEmpty)
    }

    func testDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let day = CallDates.parse("2026-09-23", calendar: calendar)
        XCTAssertEqual(day.map { CallDates.format($0, calendar: calendar) }, "2026-09-23T00:00:00+02:00")
        let end = CallDates.parse("2026-09-23", endOfDay: true, calendar: calendar)!
        XCTAssertEqual(end.timeIntervalSince(day!), 86_400 - 0.001, accuracy: 0.0001)
        XCTAssertEqual(CallDates.parse("2026-09-23T12:00:00Z"), Date(timeIntervalSince1970: 1_790_164_800))
        XCTAssertNotNil(CallDates.parse("2026-09-23T14:30", calendar: calendar))
        XCTAssertNil(CallDates.parse("yesterday"))
    }

    // MARK: Agent setup

    func testCodexConfigAddsUpdatesAndKeepsTheRest() throws {
        let added = try AgentConfig.codex("", path: "/Apps/Kaiku.app/Contents/MacOS/kaiku-mcp")
        XCTAssertEqual(added.change, .added)
        XCTAssertEqual(added.text, "[mcp_servers.kaiku]\ncommand = \"/Apps/Kaiku.app/Contents/MacOS/kaiku-mcp\"\n")

        let existing = "model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"x\""
        let appended = try AgentConfig.codex(existing, path: "/k")
        XCTAssertEqual(appended.text, existing + "\n\n[mcp_servers.kaiku]\ncommand = \"/k\"\n")

        XCTAssertEqual(try AgentConfig.codex(appended.text, path: "/k").change, .unchanged)

        let moved = try AgentConfig.codex(appended.text, path: "/new \"path\"")
        XCTAssertEqual(moved.change, .updated)
        XCTAssertEqual(moved.text, existing + "\n\n[mcp_servers.kaiku]\ncommand = \"/new \\\"path\\\"\"\n")
        XCTAssertEqual(try AgentConfig.codex(moved.text, path: "/new \"path\"").change, .unchanged)

        let noCommand = "[mcp_servers.kaiku]\nargs = []\n[other]\n"
        XCTAssertEqual(try AgentConfig.codex(noCommand, path: "/k").text, "[mcp_servers.kaiku]\ncommand = \"/k\"\nargs = []\n[other]\n")
    }

    func testCodexConfigRefusesOtherDefinitionsOfTheServer() {
        let forms = [
            "mcp_servers.kaiku.command = \"/x\"\n",
            "mcp_servers.\"kaiku\".command = \"/x\"\n",
            "[mcp_servers]\nkaiku = { command = \"/x\" }\n",
            "[mcp_servers]\nkaiku.command = \"/x\"\n",
            "mcp_servers = { kaiku = { command = \"/x\" } }\n",
        ]
        for form in forms {
            XCTAssertThrowsError(try AgentConfig.codex(form, path: "/k"), form)
        }
        XCTAssertNoThrow(try AgentConfig.codex("[mcp_servers.other]\nkaiku = 1\n[mcp_servers.kaiku]\ncommand = \"/x\"\n", path: "/k"))
    }

    func testClaudeDesktopConfigMergesIntoExistingKeys() throws {
        let created = try AgentConfig.claudeDesktop(nil, path: "/k")
        XCTAssertEqual(created.change, .added)
        let json = try JSONDecoder().decode(JSONValue.self, from: created.data)
        XCTAssertEqual(json["mcpServers"]?["kaiku"], ["command": "/k", "args": []])

        let existing = Data(#"{"globalShortcut":"Cmd+K","mcpServers":{"other":{"command":"o","args":["-x"]}}}"#.utf8)
        let merged = try AgentConfig.claudeDesktop(existing, path: "/k")
        let m = try JSONDecoder().decode(JSONValue.self, from: merged.data)
        XCTAssertEqual(m["globalShortcut"], "Cmd+K")
        XCTAssertEqual(m["mcpServers"]?["other"], ["command": "o", "args": ["-x"]])
        XCTAssertEqual(m["mcpServers"]?["kaiku"]?["command"], "/k")
        XCTAssertTrue(String(decoding: merged.data, as: UTF8.self).contains("\n  "), "pretty-printed")

        XCTAssertEqual(try AgentConfig.claudeDesktop(merged.data, path: "/k").change, .unchanged)
        XCTAssertEqual(try AgentConfig.claudeDesktop(merged.data, path: "/other").change, .updated)
        XCTAssertThrowsError(try AgentConfig.claudeDesktop(Data("[1]".utf8), path: "/k"))
        XCTAssertThrowsError(try AgentConfig.claudeDesktop(Data(#"{"mcpServers":3}"#.utf8), path: "/k"))
    }

    func testClaudeDesktopSnippetIsTheEntryAddedToTheConfig() throws {
        let path = "/My \"Apps\"/kaiku-mcp"
        let snippet = try JSONDecoder().decode(JSONValue.self, from: Data(AgentConfig.claudeDesktopSnippet(path: path).utf8))
        XCTAssertEqual(snippet["mcpServers"]?["kaiku"], ["command": .string(path), "args": []])
    }

    func testClaudeCommandLineAndShellQuoting() {
        XCTAssertEqual(AgentConfig.claudeCommandLine(path: "/Applications/Kaiku.app/Contents/MacOS/kaiku-mcp"),
                       "claude mcp add --scope user kaiku -- /Applications/Kaiku.app/Contents/MacOS/kaiku-mcp")
        XCTAssertEqual(AgentConfig.shellQuoted("/My Apps/it's"), #"'/My Apps/it'\''s'"#)
    }

    func testControlRequestURLs() {
        func parse(_ s: String) -> ControlRequest? { URL(string: s).flatMap(ControlRequest.init(url:)) }
        XCTAssertEqual(parse("kaiku://record/start?title=Weekly%20sync"), .startRecording(title: "Weekly sync"))
        XCTAssertEqual(parse("kaiku://record/start"), .startRecording(title: nil))
        XCTAssertEqual(parse("kaiku://record/stop"), .stopRecording)
        XCTAssertEqual(parse("kaiku://record/pause"), .togglePause)
        XCTAssertEqual(parse("kaiku://record/bookmark"), .addBookmark)
        XCTAssertEqual(parse("kaiku://mute/toggle"), .toggleMute)
        XCTAssertEqual(parse("kaiku://open?folder=%2Ftmp%2Fa"), .openCall(folder: "/tmp/a"))
        XCTAssertEqual(parse("kaiku://chat?q=what%20was%20decided&tag=work&days=7"),
                       .chat(question: "what was decided", tag: "work", source: nil, days: 7))
        XCTAssertNil(parse("kaiku://chat"))
        XCTAssertNil(parse("kaiku://record/erase"))
        XCTAssertNil(parse("kaiku://transcribe?folder=%2Ftmp%2Fa"))
    }

    func testAgentRequestURLsRoundTrip() {
        let path = "/Users/me/Documents/Kaiku/2026-09-23_1430_a&b=c #1"
        for request in [AgentRequest.transcribe(folder: path), .summarize(folder: path)] {
            XCTAssertEqual(request.url.scheme, "kaiku")
            XCTAssertEqual(AgentRequest(url: request.url), request)
        }
        XCTAssertNil(AgentRequest(url: URL(string: "kaiku://delete?folder=%2Fx")!))
        XCTAssertNil(AgentRequest(url: URL(string: "kaiku://transcribe")!))
    }

    func testBaseFolderDefault() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        XCTAssertEqual(KaikuAgents.baseFolder(savedPath: nil, home: home).path, "/Users/me/Documents/Kaiku")
        XCTAssertEqual(KaikuAgents.baseFolder(savedPath: "", home: home).path, "/Users/me/Documents/Kaiku")
        XCTAssertEqual(KaikuAgents.baseFolder(savedPath: "/Volumes/Calls", home: home).path, "/Volumes/Calls")
    }
}

/// The Kaiku tools on a temporary recordings folder.
final class KaikuToolsTests: XCTestCase {
    private var base: URL!
    private var allowEdits = false
    private var requests: [AgentRequest] = []
    private var changes = 0

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("kaiku-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try makeCall("2026-09-20_1000_kickoff", title: "Kickoff", day: 0, tags: ["Atlas"], source: "Zoom",
                     segments: [Segment(start: 1, end: 2, speaker: "Me", text: "Welcome to the kickoff."),
                                Segment(start: 3, end: 4, speaker: "Speaker 1", text: "Il budget è approvato.")])
        try makeCall("2026-09-23_1430_weekly", title: "Weekly sync", day: 3, tags: [], source: "Google Meet",
                     segments: [Segment(start: 5, end: 6, speaker: "Me", text: "The budget moves to November.")])
        // Not a call: no meta.json.
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Chats"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeCall(_ name: String, title: String, day: Int, tags: [String], source: String, segments: [Segment]) throws {
        let folder = RecordingFolder(url: base.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let meta = RecordingMeta(title: title, date: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400),
                                 durationSeconds: 600, language: "auto", status: .done,
                                 bookmarks: [Bookmark(time: 2, label: "Start")], tags: tags, source: source)
        try folder.saveMeta(meta)
        try folder.saveSegments(segments)
        try TranscriptWriter.write(folder: folder, meta: meta, rawSegments: segments)
    }

    private var tools: KaikuToolSet {
        KaikuToolSet(library: CallLibrary(base: base), allowEdits: { [unowned self] in self.allowEdits },
                     openInApp: { [unowned self] in self.requests.append($0) }, changed: { [unowned self] in self.changes += 1 })
    }

    private func json(_ result: MCPToolResult) throws -> JSONValue {
        XCTAssertFalse(result.isError, result.text)
        return try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
    }

    private var kickoffID: String { ChatPrompt.ref(forFolderName: "2026-09-20_1000_kickoff") }

    func testListsCallsLatestFirstWithFilters() throws {
        let all = try json(tools.call("list_calls", arguments: [:]))
        XCTAssertEqual(all["total"], 2)
        XCTAssertEqual(all["calls"]?.arrayValue?.map { $0["title"] }, ["Weekly sync", "Kickoff"])
        XCTAssertEqual(all["calls"]?.arrayValue?.last?["id"], .string(kickoffID))
        XCTAssertEqual(all["calls"]?.arrayValue?.last?["hasTranscript"], true)

        XCTAssertEqual(try json(tools.call("list_calls", arguments: ["tag": "atlas"]))["total"], 1)
        XCTAssertEqual(try json(tools.call("list_calls", arguments: ["source": "zoom"]))["total"], 1)
        XCTAssertEqual(try json(tools.call("list_calls", arguments: ["query": "WEEKLY"]))["total"], 1)
        let page = try json(tools.call("list_calls", arguments: ["limit": 1]))
        XCTAssertEqual(page["nextOffset"], 1)
        XCTAssertThrowsError(try tools.call("list_calls", arguments: ["from": "soon"]))
    }

    func testResolvesIdsFolderNamesAndPathsInsideTheBaseOnly() {
        let library = CallLibrary(base: base)
        XCTAssertEqual(library.resolve(kickoffID)?.meta.title, "Kickoff")
        XCTAssertEqual(library.resolve(kickoffID.uppercased())?.meta.title, "Kickoff")
        XCTAssertEqual(library.resolve("2026-09-20_1000_kickoff")?.meta.title, "Kickoff")
        XCTAssertEqual(library.resolve(base.appendingPathComponent("2026-09-20_1000_kickoff").path + "/")?.meta.title, "Kickoff")
        XCTAssertNil(library.resolve(base.appendingPathComponent("2026-09-20_1000_kickoff/../../etc").path))
        XCTAssertNil(library.folder(atPath: base.deletingLastPathComponent().path))
        XCTAssertNil(library.folder(atPath: base.appendingPathComponent("Chats").path))
        XCTAssertNil(library.resolve("cffffff"))
    }

    func testGetCallReadTranscriptAndSearch() throws {
        let call = try json(tools.call("get_call", arguments: ["id": .string(kickoffID)]))
        XCTAssertEqual(call["bookmarks"]?.arrayValue?.first?["time"], "00:00:02")
        XCTAssertEqual(call["speakers"]?.arrayValue?.count, 2)
        XCTAssertNotNil(call["files"]?["transcript"]?.stringValue)
        XCTAssertEqual(call["files"]?["summary"], .null)

        let page = try tools.call("read_transcript", arguments: ["id": .string(kickoffID), "limit": 1])
        XCTAssertFalse(page.isError)
        XCTAssertTrue(page.text.contains("transcript.md ("))
        XCTAssertTrue(page.text.contains("[00:00:01] Me: Welcome to the kickoff."))
        XCTAssertTrue(page.text.contains("More: offset 1."))
        XCTAssertFalse(page.text.contains("budget"))

        XCTAssertTrue(try tools.call("read_summary", arguments: ["id": .string(kickoffID)]).isError)
        XCTAssertTrue(try tools.call("get_call", arguments: ["id": "cffffff"]).isError)

        let found = try json(tools.call("search_transcripts", arguments: ["query": "BUDGET"]))
        XCTAssertEqual(found["matches"]?.arrayValue?.map { $0["title"] }, ["Weekly sync", "Kickoff"])
        let limited = try json(tools.call("search_transcripts", arguments: ["query": "budget", "limit": 1]))
        XCTAssertEqual(limited["nextOffset"], 1)
        let filtered = try json(tools.call("search_transcripts", arguments: ["query": "budget", "tag": "Atlas"]))
        XCTAssertEqual(filtered["matches"]?.arrayValue?.first?["time"], "00:00:03")
    }

    func testSemanticSearchUsesTheStoredIndexes() throws {
        struct Letters: TextEmbedder {
            func supports(language: String) -> Bool { language == "en" }
            func embed(_ text: String, language: String) -> [Float]? {
                ["b", "k", "w"].map { l in Float(text.lowercased().filter { String($0) == l }.count) }
            }
        }
        let embedder = Letters()
        let library = CallLibrary(base: base)
        let weekly = try XCTUnwrap(library.calls().first { $0.meta.title == "Weekly sync" })
        XCTAssertNotNil(SemanticIndexer.build(weekly.folder, meta: weekly.meta, embedder: embedder))
        let tools = KaikuToolSet(library: library, allowEdits: { false }, embedder: embedder)

        let found = try json(tools.call("semantic_search", arguments: ["query": "budget"]))
        XCTAssertEqual(found["matches"]?.arrayValue?.map { $0["title"] }, ["Weekly sync"])
        XCTAssertEqual(found["matches"]?.arrayValue?.first?["time"], "00:00:05")
        XCTAssertNotNil(found["note"]?.stringValue)
        let none = try json(tools.call("semantic_search", arguments: ["query": "budget", "tag": "Atlas"]))
        XCTAssertEqual(none["matches"]?.arrayValue?.count, 0)
        XCTAssertThrowsError(try tools.call("semantic_search", arguments: [:]))
    }

    func testEditToolsOnlyWhenAllowed() throws {
        XCTAssertEqual(tools.tools().map(\.name), KaikuToolSet.readToolNames)
        let refused = try tools.call("rename_call", arguments: ["id": .string(kickoffID), "title": "New"])
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(CallLibrary(base: base).resolve(kickoffID)?.meta.title, "Kickoff")

        allowEdits = true
        XCTAssertEqual(tools.tools().map(\.name), KaikuToolSet.readToolNames + KaikuToolSet.editToolNames)
        XCTAssertFalse(try tools.call("rename_call", arguments: ["id": .string(kickoffID), "title": "Kickoff Atlas"]).isError)
        XCTAssertFalse(try tools.call("set_tags", arguments: ["id": .string(kickoffID), "add": ["Q4"], "remove": ["atlas"]]).isError)
        XCTAssertFalse(try tools.call("rename_speaker", arguments: ["id": .string(kickoffID), "speaker": "speaker 1", "name": "Anna"]).isError)
        XCTAssertTrue(try tools.call("rename_speaker", arguments: ["id": .string(kickoffID), "speaker": "Bob", "name": "B"]).isError)
        XCTAssertThrowsError(try tools.call("set_tags", arguments: ["id": .string(kickoffID)]))

        let entry = CallLibrary(base: base).resolve(kickoffID)
        XCTAssertEqual(entry?.meta.title, "Kickoff Atlas")
        XCTAssertEqual(entry?.meta.tags, ["Q4"])
        XCTAssertEqual(entry?.meta.speakerNames, ["Speaker 1": "Anna"])
        let transcript = try String(contentsOf: entry!.folder.transcriptURL, encoding: .utf8)
        XCTAssertTrue(transcript.hasPrefix("# Kickoff Atlas\n"))
        XCTAssertTrue(transcript.contains("Anna:** Il budget"))
        XCTAssertTrue(transcript.contains("**Tags:** Q4"))
        XCTAssertEqual(changes, 3)

        // Renaming by the name shown, and back to the label.
        XCTAssertFalse(try tools.call("rename_speaker", arguments: ["id": .string(kickoffID), "speaker": "Anna", "name": ""]).isError)
        XCTAssertNil(CallLibrary(base: base).resolve(kickoffID)?.meta.speakerNames)

        XCTAssertTrue(try tools.call("transcribe_again", arguments: ["id": .string(kickoffID)]).isError, "no audio")
        XCTAssertFalse(try tools.call("summarize_again", arguments: ["id": .string(kickoffID)]).isError)
        XCTAssertEqual(requests, [.summarize(folder: entry!.folder.url.path)])
    }

    func testTagEdits() {
        XCTAssertEqual(KaikuToolSet.tags(current: ["A", "B"], replace: nil, add: ["c", "a"], remove: ["b"]), ["A", "c"])
        XCTAssertEqual(KaikuToolSet.tags(current: ["A"], replace: ["X"], add: [], remove: []), ["X"])
        XCTAssertEqual(KaikuToolSet.tags(current: ["A"], replace: [], add: [], remove: []), [])
    }
}
