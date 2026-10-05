import XCTest
@testable import KaikuCore

final class ProviderSupportTests: XCTestCase {
    func testMultipartFormBody() throws {
        var form = MultipartForm()
        form.field("model", "whisper-1")
        form.file("file", data: Data("abc".utf8), filename: "a.m4a", mime: "audio/mp4")
        XCTAssertTrue(form.contentType.hasPrefix("multipart/form-data; boundary=kaiku-"))
        let text = String(decoding: form.finalized(), as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"a.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nabc\r\n"))
        XCTAssertTrue(text.hasSuffix("--\(form.boundary)--\r\n"))
    }

    func testChunkCacheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = TrackCache.Key(provider: "OpenAI (x)", language: nil, trim: nil, audioBytes: 10, audioModified: 1)
        let cache = ChunkCache(url: url, key: key)
        XCTAssertNil(cache.result(index: 0, offset: 0))
        let result = TranscriptionResult(segments: [Segment(start: 1, end: 2, text: "hi")], detectedLanguage: "en")
        cache.save(result, index: 0, offset: 0)

        let reloaded = ChunkCache(url: url, key: key)
        XCTAssertEqual(reloaded.result(index: 0, offset: 0)?.segments, result.segments)
        XCTAssertEqual(reloaded.result(index: 0, offset: 0)?.detectedLanguage, "en")
        XCTAssertNil(reloaded.result(index: 0, offset: 600))

        var other = key
        other.language = "it"
        XCTAssertNil(ChunkCache(url: url, key: other).result(index: 0, offset: 0))
    }

    func testAnthropicEndpointTarget() {
        let endpoint = LLMEndpoint(name: "Anthropic", style: .anthropic, apiKey: "k")
        XCTAssertEqual(endpoint.target.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(endpoint.target.headers, ["x-api-key": "k", "anthropic-version": "2023-06-01"])
    }

    func testChatCompletionsEndpointTarget() {
        let keyed = LLMEndpoint(name: "OpenAI", style: .chatCompletions(base: "https://api.openai.com/v1"), apiKey: "k")
        XCTAssertEqual(keyed.target.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(keyed.target.headers, ["Authorization": "Bearer k"])
        // Local servers usually take no key.
        let local = LLMEndpoint(name: "Ollama", style: .chatCompletions(base: "http://localhost:11434/v1"), apiKey: "")
        XCTAssertEqual(local.target.headers, [:])
    }

    func testChatCompletionsBase() {
        XCTAssertEqual(SummaryProviderKind.openAI.chatCompletionsBase(baseURL: ""), "https://api.openai.com/v1")
        XCTAssertEqual(SummaryProviderKind.groq.chatCompletionsBase(baseURL: ""), "https://api.groq.com/openai/v1")
        XCTAssertEqual(SummaryProviderKind.openRouter.chatCompletionsBase(baseURL: ""), "https://openrouter.ai/api/v1")
        XCTAssertNil(SummaryProviderKind.anthropic.chatCompletionsBase(baseURL: ""))
        XCTAssertNil(SummaryProviderKind.claudeCode.chatCompletionsBase(baseURL: ""))
        XCTAssertNil(SummaryProviderKind.custom.chatCompletionsBase(baseURL: ""))
        XCTAssertEqual(SummaryProviderKind.custom.chatCompletionsBase(baseURL: "http://localhost:1234/v1"), "http://localhost:1234/v1")
        XCTAssertEqual(SummaryProviderKind.ollama.chatCompletionsBase(baseURL: ""), LocalLLM.ollamaChatBase(""))
    }

    func testProbeURL() {
        XCTAssertNil(SummaryProviderKind.openAI.probeURL(baseURL: ""))
        XCTAssertNil(SummaryProviderKind.custom.probeURL(baseURL: ""))
        XCTAssertEqual(SummaryProviderKind.custom.probeURL(baseURL: "http://localhost:1234/v1")?.absoluteString,
                       "http://localhost:1234/v1/models")
        XCTAssertEqual(SummaryProviderKind.ollama.probeURL(baseURL: "")?.path, "/api/tags")
    }

    func testKeyCheckRequests() {
        let openAI = KeyCheck.request(.openAI, key: "k")
        XCTAssertEqual(openAI.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let anthropic = KeyCheck.request(.anthropic, key: "k")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(anthropic.value(forHTTPHeaderField: "Authorization"))
        let eleven = KeyCheck.request(.elevenLabs, key: "k")
        XCTAssertEqual(eleven.url?.absoluteString, "https://api.elevenlabs.io/v1/user")
        XCTAssertEqual(eleven.value(forHTTPHeaderField: "xi-api-key"), "k")
        XCTAssertEqual(KeyCheck.request(.groq, key: "k").url?.host, "api.groq.com")
        XCTAssertEqual(KeyCheck.request(.openRouter, key: "k").url?.path, "/api/v1/key")
    }

    func testKeyCheckStatusMessages() {
        XCTAssertEqual(KeyCheck.result(status: 200, name: "OpenAI").message, "The key works.")
        XCTAssertTrue(KeyCheck.result(status: 200, name: "OpenAI").ok)
        XCTAssertEqual(KeyCheck.result(status: 401, name: "Groq").message, "Groq refused the key (HTTP 401).")
        XCTAssertEqual(KeyCheck.result(status: 403, name: "Groq").message, "Groq refused the key (HTTP 403).")
        XCTAssertFalse(KeyCheck.result(status: 403, name: "Groq").ok)
        XCTAssertEqual(KeyCheck.result(status: 500, name: "Anthropic").message, "Anthropic answered HTTP 500.")
        XCTAssertEqual(KeyCheck.result(status: 0, name: "Anthropic").message, "Anthropic answered HTTP 0.")
    }
}
