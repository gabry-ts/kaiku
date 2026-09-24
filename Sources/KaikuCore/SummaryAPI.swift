import Foundation

/// Request bodies and response parsing for the optional call summary.
public enum SummaryAPI {
    public static let defaultPrompt = """
    Summarize this call transcript. Write in the same language as the transcript.

    Use Markdown with these sections:
    ## Summary
    A few sentences on what the call was about.
    ## Decisions
    Bullet points, or "None".
    ## Action items
    Bullet points with the owner when it is clear, or "None".

    Be concise. Do not invent anything that is not in the transcript.

    Title: {{title}}

    Transcript:
    {{transcript}}
    """

    /// Fills `{{title}}` and `{{transcript}}`. If the template has no `{{transcript}}`,
    /// the transcript is appended so the model always gets it.
    public static func renderPrompt(template: String, title: String, transcript: String) -> String {
        let base = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPrompt : template
        var out = WebhookTemplate.render(base, values: ["title": .string(title), "transcript": .string(transcript)], jsonEscape: false)
        if !base.contains("{{transcript}}") { out += "\n\nTranscript:\n" + transcript }
        return out
    }

    /// OpenAI-compatible `/chat/completions` body (OpenAI, Groq).
    public static func chatCompletionsBody(model: String, prompt: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ] as [String: Any])
    }

    /// Anthropic Messages API body.
    public static func anthropicBody(model: String, prompt: String, maxTokens: Int = 4096) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ] as [String: Any])
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct AnthropicResponse: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
    }

    public static func parseChatCompletions(_ data: Data) throws -> String {
        let r: ChatResponse
        do { r = try JSONDecoder().decode(ChatResponse.self, from: data) }
        catch { throw ParseError.invalid("chat completion JSON: \(error)") }
        let text = (r.choices.first?.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.invalid("empty summary") }
        return text
    }

    public static func parseAnthropic(_ data: Data) throws -> String {
        let r: AnthropicResponse
        do { r = try JSONDecoder().decode(AnthropicResponse.self, from: data) }
        catch { throw ParseError.invalid("Anthropic JSON: \(error)") }
        let text = r.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.invalid("empty summary") }
        return text
    }
}
