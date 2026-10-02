import Foundation

/// What a streaming answer says, line by line, in the terms the chat shares across providers.
public enum ChatStreamEvent: Equatable, Sendable {
    /// More text, to add to what came before.
    case text(String)
    /// A new message starts: what came before was the tool's own preamble.
    case reset
    /// The tool is using one of its tools, e.g. "Read".
    case tool(String)
    /// The whole answer.
    case final(String)
    case done
    case error(String)
    case ignored
}

/// Request bodies and stream parsing for chatting with calls.
public enum ChatAPI {
    /// Anthropic Messages API body, streamed. Consecutive messages of the same role are joined.
    public static func anthropicBody(model: String, system: String, messages: [ChatMessage], maxTokens: Int = 4096) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": joined(messages).map { ["role": $0.role.rawValue, "content": $0.text] },
        ] as [String: Any])
    }

    /// OpenAI-compatible `/chat/completions` body (OpenAI, Groq, OpenRouter), streamed.
    public static func chatCompletionsBody(model: String, system: String, messages: [ChatMessage]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "messages": [["role": "system", "content": system]]
                + joined(messages).map { ["role": $0.role.rawValue, "content": $0.text] },
        ] as [String: Any])
    }

    /// The messages with consecutive ones of the same role joined, as the APIs want them alternating.
    static func joined(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for m in messages {
            if var last = out.last, last.role == m.role {
                last.text += "\n\n" + m.text
                out[out.count - 1] = last
            } else {
                out.append(m)
            }
        }
        return out
    }

    /// One line of an Anthropic server-sent event stream.
    public static func parseAnthropic(_ line: String) -> ChatStreamEvent {
        guard let event = json(sseData(line)), let type = event["type"] as? String else { return .ignored }
        switch type {
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String else { return .ignored }
            return .text(text)
        case "message_stop":
            return .done
        case "error":
            return .error(errorMessage(event["error"]) ?? "unknown error")
        default:
            return .ignored
        }
    }

    /// One line of an OpenAI-compatible server-sent event stream.
    public static func parseChatCompletions(_ line: String) -> ChatStreamEvent {
        guard let data = sseData(line) else { return .ignored }
        if data == "[DONE]" { return .done }
        guard let event = json(data) else { return .ignored }
        if let error = event["error"] { return .error(errorMessage(error) ?? "unknown error") }
        let choice = (event["choices"] as? [[String: Any]])?.first
        guard let text = (choice?["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty else { return .ignored }
        return .text(text)
    }

    /// One line of Claude Code's `--output-format stream-json --include-partial-messages`.
    public static func parseClaudeCode(_ line: String) -> ChatStreamEvent {
        guard let event = json(line), let type = event["type"] as? String else { return .ignored }
        switch type {
        case "stream_event":
            guard let inner = event["event"] as? [String: Any], let innerType = inner["type"] as? String else { return .ignored }
            if innerType == "message_start" { return .reset }
            let delta = inner["delta"] as? [String: Any]
            guard innerType == "content_block_delta", delta?["type"] as? String == "text_delta",
                  let text = delta?["text"] as? String else { return .ignored }
            return .text(text)
        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            guard let tool = content.first(where: { $0["type"] as? String == "tool_use" })?["name"] as? String else { return .ignored }
            return .tool(tool)
        case "result":
            let result = event["result"] as? String ?? ""
            if event["is_error"] as? Bool == true { return .error(result.isEmpty ? "Claude Code failed." : result) }
            return .final(result)
        default:
            return .ignored
        }
    }

    /// True for the lines OpenCode prints when it uses a tool (`|  Read     path`), which
    /// are not part of the answer. Table rows end with `|` and are kept.
    public static func isOpenCodeToolLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && !trimmed.hasSuffix("|")
    }

    /// The payload of a `data:` line, nil for other lines (event names, comments, blank lines).
    static func sseData(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    }

    private static func json(_ text: String?) -> [String: Any]? {
        guard let text, !text.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func errorMessage(_ error: Any?) -> String? {
        if let text = error as? String { return text }
        return (error as? [String: Any])?["message"] as? String
    }
}
