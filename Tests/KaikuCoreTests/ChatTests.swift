import XCTest
@testable import KaikuCore

final class ChatTests: XCTestCase {
    private func call(_ ref: String, _ title: String, day: Int, duration: Double = 600) -> ChatCall {
        ChatCall(ref: ref, path: "/calls/\(ref)", title: title,
                 date: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400), duration: duration)
    }

    private func context(_ call: ChatCall, characters: Int) -> ChatContextCall {
        let line = "**[00:00:01] Me:** " + String(repeating: "a", count: 80)
        let lines = Array(repeating: line, count: max(1, characters / (line.count + 2)))
        return ChatContextCall(call: call, transcript: lines.joined(separator: "\n\n"))
    }

    // MARK: Citations

    func testParsesSingleAndGroupedCitations() {
        XCTAssertEqual(ChatCitations.parse("c3fa9b2 00:12:34"), [ChatCitation(ref: "c3fa9b2", time: 754)])
        XCTAssertEqual(ChatCitations.parse("C3FA9B2, 12:34"), [ChatCitation(ref: "c3fa9b2", time: 754)])
        XCTAssertEqual(ChatCitations.parse("c3fa9b2 00:01:00; c1d2e3f 1:02:03"),
                       [ChatCitation(ref: "c3fa9b2", time: 60), ChatCitation(ref: "c1d2e3f", time: 3723)])
        // Several times of one call, and a call without a time.
        XCTAssertEqual(ChatCitations.parse("c3fa9b2 00:01:00, 00:02:00; c1d2e3f"),
                       [ChatCitation(ref: "c3fa9b2", time: 60), ChatCitation(ref: "c3fa9b2", time: 120),
                        ChatCitation(ref: "c1d2e3f", time: nil)])
    }

    func testLeavesOtherBracketsAlone() {
        XCTAssertNil(ChatCitations.parse("see 12:30"))
        XCTAssertNil(ChatCitations.parse("12:30"))
        XCTAssertNil(ChatCitations.parse("c3fa9b2 is the id"))
        XCTAssertNil(ChatCitations.parse("c3fa9b2 00:75:00"))
        XCTAssertTrue(ChatCitations.find("A [link](https://x.y) and [Earlier part of the call left out]").isEmpty)
    }

    func testLinksCitationsWithTitlesAndKeepsUnknownOnes() {
        let text = "Billing moves to November [c3fa9b2 00:03:42; cffffff 00:01:00]. Done [c3fa9b2]."
        let out = ChatCitations.linked(text) { $0 == "c3fa9b2" ? "Weekly [sync]" : nil }
        XCTAssertEqual(out, "Billing moves to November ([Weekly (sync) · 3:42](kaiku-chat://cite?call=c3fa9b2&t=222), cffffff 1:00). "
                       + "Done ([Weekly (sync)](kaiku-chat://cite?call=c3fa9b2)).")
    }

    func testCitationURLRoundTrip() {
        let c = ChatCitation(ref: "c3fa9b2", time: 3723)
        XCTAssertEqual(ChatCitations.citation(from: ChatCitations.url(for: c)), c)
        XCTAssertEqual(ChatCitations.citation(from: ChatCitations.url(for: ChatCitation(ref: "c3fa9b2", time: nil))),
                       ChatCitation(ref: "c3fa9b2", time: nil))
        XCTAssertNil(ChatCitations.citation(from: URL(string: "https://example.com/?call=c3fa9b2")!))
        XCTAssertEqual(ChatCitations.shortTime(222), "3:42")
        XCTAssertEqual(ChatCitations.shortTime(3723), "1:02:03")
    }

    func testRefIsStableAndShort() {
        let ref = ChatPrompt.ref(forFolderName: "2026-09-23_1430_weekly-sync")
        XCTAssertEqual(ref, ChatPrompt.ref(forFolderName: "2026-09-23_1430_weekly-sync"))
        XCTAssertNotEqual(ref, ChatPrompt.ref(forFolderName: "2026-09-23_1431_weekly-sync"))
        XCTAssertEqual(ref.count, 7)
        XCTAssertEqual(ChatCitations.parse(ref + " 00:00:05"), [ChatCitation(ref: ref, time: 5)])
    }

    // MARK: Context

    func testPackKeepsTheMostRecentCallsThatFitInDateOrder() {
        let old = context(call("c000001", "Old", day: 1), characters: 4_000)
        let mid = context(call("c000002", "Mid", day: 2), characters: 4_000)
        let new = context(call("c000003", "New", day: 3), characters: 4_000)
        let size = ChatPrompt.block(new).count + 2
        let packing = ChatPrompt.pack([mid, old, new], budgetCharacters: size * 2 + 10)
        XCTAssertEqual(packing.included.map(\.call.ref), ["c000002", "c000003"])
        XCTAssertEqual(packing.omitted.map(\.ref), ["c000001"])
        XCTAssertFalse(packing.truncated)

        let all = ChatPrompt.pack([mid, old, new], budgetCharacters: 1_000_000)
        XCTAssertEqual(all.included.map(\.call.ref), ["c000001", "c000002", "c000003"])
        XCTAssertTrue(all.omitted.isEmpty)
    }

    func testPackCutsAOneCallThatIsTooLong() {
        let big = context(call("c000001", "Big", day: 1), characters: 20_000)
        let packing = ChatPrompt.pack([big], budgetCharacters: 2_000)
        XCTAssertTrue(packing.truncated)
        XCTAssertEqual(packing.included.count, 1)
        XCTAssertTrue(packing.included[0].transcript.hasSuffix(ChatPrompt.truncatedNote))
        XCTAssertLessThanOrEqual(ChatPrompt.block(packing.included[0]).count, 2_000)
        XCTAssertTrue(packing.omitted.isEmpty)
    }

    func testAPISystemListsCallsAndWhatWasLeftOut() {
        let a = context(call("c000001", "Old \"one\"", day: 1), characters: 300)
        let b = context(call("c000002", "New", day: 2), characters: 300)
        let packing = ChatPacking(included: [b], omitted: [a.call], truncated: false)
        let system = ChatPrompt.apiSystem(packing)
        XCTAssertTrue(system.contains("[c000002 00:12:34]"))
        XCTAssertTrue(system.contains("<call id=\"c000002\" title=\"New\""))
        XCTAssertTrue(system.contains("c000001 \"Old \"one\"\""))
        XCTAssertFalse(system.contains("<call id=\"c000001\""))
        XCTAssertEqual(ChatPrompt.estimatedTokens(characters: 4_001), 1_001)
    }

    func testTranscriptBodyDropsTheHeader() {
        let md = "# Sync\n\n- **Date:** 2026-09-23 14:30\n\n---\n\n**[00:00:01] Me:** Hi\n"
        XCTAssertEqual(ChatPrompt.transcriptBody(md), "**[00:00:01] Me:** Hi")
        XCTAssertEqual(ChatPrompt.transcriptBody("**[00:00:01] Me:** Hi"), "**[00:00:01] Me:** Hi")
    }

    func testCLIPromptListsFilesAndHistory() {
        let files = [ChatCallFiles(call: call("c000001", "Sync", day: 1), transcriptPath: "/calls/a/transcript.md",
                                   summaryPath: "/calls/a/summary.md")]
        let history = [ChatMessage(role: .user, text: "What was decided?"), ChatMessage(role: .assistant, text: "Ship it.")]
        let prompt = ChatPrompt.cliPrompt(files: files, history: history, question: "When?")
        XCTAssertTrue(prompt.contains("- c000001: \"Sync\""))
        XCTAssertTrue(prompt.contains("Transcript: /calls/a/transcript.md"))
        XCTAssertTrue(prompt.contains("Summary: /calls/a/summary.md"))
        XCTAssertTrue(prompt.contains("User: What was decided?\n\nAssistant: Ship it."))
        XCTAssertTrue(prompt.hasSuffix("Question: When?"))
    }

    func testRecentHistoryStartsWithAQuestion() {
        let messages = (0..<10).map { i in ChatMessage(role: i % 2 == 0 ? .user : .assistant, text: "m\(i)") }
        XCTAssertEqual(ChatPrompt.recent(messages, count: 3).map(\.text), ["m8", "m9"])
        XCTAssertEqual(ChatPrompt.recent(messages, count: 4).map(\.text), ["m6", "m7", "m8", "m9"])
        XCTAssertEqual(ChatPrompt.recent(messages, characters: 5).map(\.text), ["m8", "m9"])
    }

    func testLastDaysCoversWholeDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13 UTC
        let week = ChatPeriod.lastDays(7, now: now, calendar: calendar)
        XCTAssertEqual(week.lowerBound, calendar.startOfDay(for: now).addingTimeInterval(-6 * 86_400))
        XCTAssertTrue(week.contains(now.addingTimeInterval(3_600)))
        XCTAssertFalse(week.contains(calendar.startOfDay(for: now).addingTimeInterval(86_400)))
        let range = ChatPeriod.range(from: now, to: now.addingTimeInterval(-86_400), calendar: calendar)
        XCTAssertEqual(range.lowerBound, calendar.startOfDay(for: now).addingTimeInterval(-86_400))
    }

    // MARK: Storage

    func testConversationRoundTripsThroughJSON() throws {
        var chat = ChatConversation(title: "Decisions", created: Date(timeIntervalSince1970: 1_790_000_000),
                                    calls: [call("c000001", "Sync", day: 1)], provider: "anthropic", model: "claude-sonnet-5")
        chat.messages = [ChatMessage(role: .user, text: "What?", date: Date(timeIntervalSince1970: 1_790_000_100)),
                         ChatMessage(role: .assistant, text: "This [c000001 00:00:05].", date: Date(timeIntervalSince1970: 1_790_000_101))]
        let data = try ChatStore.encode(chat)
        XCTAssertEqual(try ChatStore.decode(data), chat)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"created\" : \"2026-09-21T"))
        XCTAssertTrue(json.contains("\"role\" : \"assistant\""))
    }

    func testStoreSavesListsAndDeletes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ChatStore(directory: dir)
        XCTAssertTrue(store.all().isEmpty)
        var older = ChatConversation(title: "Older")
        older.updated = Date(timeIntervalSince1970: 1_000)
        var newer = ChatConversation(title: "Newer")
        newer.updated = Date(timeIntervalSince1970: 2_000)
        try store.save(older)
        try store.save(newer)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        XCTAssertEqual(store.all().map(\.title), ["Newer", "Older"])
        try store.delete(older.id)
        XCTAssertEqual(store.all().map(\.id), [newer.id])
        XCTAssertNoThrow(try store.delete(older.id))
    }

    func testTitleFromFirstQuestion() {
        XCTAssertEqual(ChatConversation.title(from: "What did we decide?\nmore"), "What did we decide?")
        let long = String(repeating: "word ", count: 30)
        let title = ChatConversation.title(from: long)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, ChatConversation.titleLength + 1)
    }

    // MARK: Streams

    func testLineBufferJoinsPiecesAndKeepsSplitCharacters() {
        var buffer = LineBuffer()
        let bytes = Array("caffè\r\nsecond\nlast".utf8)
        // Split inside "è".
        XCTAssertEqual(buffer.append(Data(bytes[0..<4])), [])
        XCTAssertEqual(buffer.append(Data(bytes[4..<15])), ["caffè", "second"])
        XCTAssertEqual(buffer.append(Data(bytes[15...])), [])
        XCTAssertEqual(buffer.flush(), "last")
        XCTAssertNil(buffer.flush())
    }

    func testParsesAnthropicStream() {
        XCTAssertEqual(ChatAPI.parseAnthropic("event: content_block_delta"), .ignored)
        XCTAssertEqual(ChatAPI.parseAnthropic(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#), .text("Hi"))
        XCTAssertEqual(ChatAPI.parseAnthropic(#"data: {"type":"message_stop"}"#), .done)
        XCTAssertEqual(ChatAPI.parseAnthropic(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#), .error("Overloaded"))
        XCTAssertEqual(ChatAPI.parseAnthropic(#"data: {"type":"ping"}"#), .ignored)
    }

    func testParsesChatCompletionsStream() {
        XCTAssertEqual(ChatAPI.parseChatCompletions(#"data: {"choices":[{"index":0,"delta":{"content":"Hel"}}]}"#), .text("Hel"))
        XCTAssertEqual(ChatAPI.parseChatCompletions(#"data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#), .ignored)
        XCTAssertEqual(ChatAPI.parseChatCompletions(": OPENROUTER PROCESSING"), .ignored)
        XCTAssertEqual(ChatAPI.parseChatCompletions("data: [DONE]"), .done)
        XCTAssertEqual(ChatAPI.parseChatCompletions(#"data: {"error":{"message":"Rate limited"}}"#), .error("Rate limited"))
    }

    func testParsesClaudeCodeStream() {
        XCTAssertEqual(ChatAPI.parseClaudeCode(#"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#), .reset)
        XCTAssertEqual(ChatAPI.parseClaudeCode(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Yes"}}}"#), .text("Yes"))
        XCTAssertEqual(ChatAPI.parseClaudeCode(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#), .tool("Read"))
        XCTAssertEqual(ChatAPI.parseClaudeCode(#"{"type":"result","subtype":"success","is_error":false,"result":"Final"}"#), .answer("Final"))
        XCTAssertEqual(ChatAPI.parseClaudeCode(#"{"type":"result","is_error":true,"result":"Not logged in"}"#), .error("Not logged in"))
        XCTAssertEqual(ChatAPI.parseClaudeCode("plain text"), .ignored)
        XCTAssertTrue(ChatAPI.isOpenCodeToolLine("|  Read     Users/me/transcript.md"))
        XCTAssertFalse(ChatAPI.isOpenCodeToolLine("| a | b |"))
        XCTAssertFalse(ChatAPI.isOpenCodeToolLine("The answer"))
    }

    func testBodiesStreamAndJoinMessagesOfOneRole() throws {
        let messages = [ChatMessage(role: .user, text: "a"), ChatMessage(role: .user, text: "b"),
                        ChatMessage(role: .assistant, text: "c"), ChatMessage(role: .user, text: "d")]
        let anthropic = try JSONSerialization.jsonObject(with: ChatAPI.anthropicBody(model: "m", system: "S", messages: messages)) as? [String: Any]
        XCTAssertEqual(anthropic?["stream"] as? Bool, true)
        XCTAssertEqual(anthropic?["system"] as? String, "S")
        let sent = anthropic?["messages"] as? [[String: String]]
        XCTAssertEqual(sent?.map { $0["role"] ?? "" }, ["user", "assistant", "user"])
        XCTAssertEqual(sent?.first?["content"], "a\n\nb")

        let openAI = try JSONSerialization.jsonObject(with: ChatAPI.chatCompletionsBody(model: "m", system: "S", messages: messages)) as? [String: Any]
        let chat = openAI?["messages"] as? [[String: String]]
        XCTAssertEqual(chat?.map { $0["role"] ?? "" }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(openAI?["stream"] as? Bool, true)
    }

    func testChatArguments() {
        let claude = CLITool.claude.chatArguments(model: "sonnet", workDir: "/tmp/w", outputFile: "", readableDirs: ["/calls/a", "/calls/b"])
        XCTAssertEqual(claude[claude.firstIndex(of: "--output-format")! + 1], "stream-json")
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "Read,Grep,Glob")
        XCTAssertEqual(Array(claude.suffix(3)), ["--add-dir", "/calls/a", "/calls/b"])
        XCTAssertEqual(claude[claude.firstIndex(of: "--model")! + 1], "sonnet")
        XCTAssertEqual(CLITool.codex.chatArguments(model: "", workDir: "/tmp/w", outputFile: "/tmp/o", readableDirs: ["/calls/a"]),
                       CLITool.codex.arguments(model: "", workDir: "/tmp/w", outputFile: "/tmp/o"))
        XCTAssertEqual(CLITool.opencode.chatArguments(model: "", workDir: "/calls", outputFile: "", readableDirs: []),
                       ["run", "--pure", "--dir", "/calls", "--agent", "plan"])
    }
}
