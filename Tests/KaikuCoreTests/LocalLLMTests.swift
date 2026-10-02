import XCTest
@testable import KaikuCore

final class LocalLLMTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(LocalLLM.normalize("  localhost:1234/v1/ "), "http://localhost:1234/v1")
        XCTAssertEqual(LocalLLM.normalize("https://example.com//"), "https://example.com")
        XCTAssertEqual(LocalLLM.normalize("   "), "")
    }

    func testOllamaURLs() {
        XCTAssertEqual(LocalLLM.ollamaChatBase(""), "http://localhost:11434/v1")
        XCTAssertEqual(LocalLLM.ollamaChatBase("http://10.0.0.5:11434/"), "http://10.0.0.5:11434/v1")
        XCTAssertEqual(LocalLLM.ollamaChatBase("http://localhost:11434/v1"), "http://localhost:11434/v1")
        XCTAssertEqual(LocalLLM.ollamaTagsURL("localhost:11434")?.absoluteString, "http://localhost:11434/api/tags")
    }

    func testCustomURLs() {
        XCTAssertNil(LocalLLM.customChatBase(" "))
        XCTAssertEqual(LocalLLM.customChatBase("http://localhost:1234/v1/"), "http://localhost:1234/v1")
        XCTAssertEqual(LocalLLM.customModelsURL("http://localhost:1234/v1")?.absoluteString, "http://localhost:1234/v1/models")
        XCTAssertNil(LocalLLM.customModelsURL(""))
    }

    func testParseOllamaTags() throws {
        let json = #"{"models":[{"name":"qwen3:8b","model":"qwen3:8b","size":1},{"name":"llama3.2:latest"}]}"#
        XCTAssertEqual(try LocalLLM.parseOllamaTags(Data(json.utf8)), ["llama3.2:latest", "qwen3:8b"])
        XCTAssertEqual(try LocalLLM.parseOllamaTags(Data(#"{"models":[]}"#.utf8)), [])
        XCTAssertThrowsError(try LocalLLM.parseOllamaTags(Data("nope".utf8)))
    }
}
