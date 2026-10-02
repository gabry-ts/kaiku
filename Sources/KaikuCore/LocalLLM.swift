import Foundation

/// URLs and parsing for LLM servers running locally: Ollama and OpenAI-compatible ones
/// (LM Studio, llama.cpp server and similar).
public enum LocalLLM {
    public static let ollamaDefaultBase = "http://localhost:11434"

    /// Trims spaces and trailing slashes and adds `http://` when no scheme was typed. Empty stays empty.
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The Ollama server address, without a `/v1` the user may have added.
    static func ollamaRoot(_ raw: String) -> String {
        var s = normalize(raw.isEmpty ? ollamaDefaultBase : raw)
        if s.hasSuffix("/v1") { s.removeLast(3) }
        return s
    }

    /// Base of Ollama's OpenAI-compatible API; `/chat/completions` goes after it.
    public static func ollamaChatBase(_ raw: String) -> String { ollamaRoot(raw) + "/v1" }

    /// Where Ollama lists its installed models.
    public static func ollamaTagsURL(_ raw: String) -> URL? { URL(string: ollamaRoot(raw) + "/api/tags") }

    /// Base of a custom OpenAI-compatible server, nil when none was set.
    public static func customChatBase(_ raw: String) -> String? {
        let s = normalize(raw)
        return s.isEmpty ? nil : s
    }

    /// Where a custom server lists its models, used to tell whether it is running.
    public static func customModelsURL(_ raw: String) -> URL? {
        customChatBase(raw).flatMap { URL(string: $0 + "/models") }
    }

    private struct Tags: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    /// Model names from Ollama's `GET /api/tags` response, sorted.
    public static func parseOllamaTags(_ data: Data) throws -> [String] {
        do { return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name).sorted() }
        catch { throw ParseError.invalid("Ollama model list JSON: \(error)") }
    }
}
