import Foundation
import KaikuCore

/// Writes summary.md for a call with the user's own API key. Only runs when
/// enabled in Settings or when asked from the Library.
enum SummaryJob {
    static func run(folder: RecordingFolder, provider kind: SummaryProviderKind = AppSettings.summaryProvider) async throws {
        guard let transcript = try? String(contentsOf: folder.transcriptURL, encoding: .utf8) else {
            throw ProviderError(message: "This call has no transcript yet.")
        }
        if let problem = kind.problem {
            throw ProviderError(message: "\(problem) Check Settings > Transcription > Summary.")
        }
        let meta = folder.loadMeta()
        let model = AppSettings.summaryModel(for: kind)
        let prompt = SummaryAPI.renderPrompt(template: AppSettings.summaryPrompt, title: meta?.title ?? "", transcript: transcript)

        let text = try await complete(kind: kind, model: model, prompt: prompt)
        try (text + "\n").write(to: folder.summaryURL, atomically: true, encoding: .utf8)
        folder.updateMeta { $0.summaryModel = "\(kind.displayName) (\(model))" }
    }

    /// Sends one prompt to the provider and returns the text of its answer.
    /// `maxTokens` only applies to HTTP APIs.
    static func complete(kind: SummaryProviderKind, model: String, prompt: String,
                         maxTokens: Int = 4096, timeout: TimeInterval = 300) async throws -> String {
        if let cli = kind.cli {
            return try await CLIProviders.complete(cli, name: kind.displayName, model: model, prompt: prompt, timeout: timeout)
        }
        if let problem = kind.problem { throw ProviderError(message: problem) }
        if kind.requiresModel, model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ProviderError(message: "\(kind.displayName) needs a model.")
        }
        let key = kind.apiKey ?? ""
        switch kind {
        case .anthropic:
            let data = try await HTTP.postJSON(
                URL(string: "https://api.anthropic.com/v1/messages")!,
                body: try SummaryAPI.anthropicBody(model: model, prompt: prompt, maxTokens: maxTokens),
                headers: ["x-api-key": key, "anthropic-version": "2023-06-01"], timeout: timeout)
            return try SummaryAPI.parseAnthropic(data)
        case .openAI, .groq, .openRouter:
            let base: String
            switch kind {
            case .openAI: base = "https://api.openai.com/v1"
            case .groq: base = "https://api.groq.com/openai/v1"
            default: base = "https://openrouter.ai/api/v1"
            }
            let data = try await HTTP.postJSON(
                URL(string: base + "/chat/completions")!,
                body: try SummaryAPI.chatCompletionsBody(model: model, prompt: prompt),
                headers: ["Authorization": "Bearer \(key)"], timeout: timeout)
            return try SummaryAPI.parseChatCompletions(data)
        case .claudeCode, .codex, .opencode:
            throw ProviderError(message: "\(kind.displayName) runs as a command-line tool.")
        }
    }
}

extension HTTP {
    static func postJSON(_ url: URL, body: Data, headers: [String: String], timeout: TimeInterval = 300) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data.prefix(600), encoding: .utf8) ?? ""
            throw ProviderError(message: "HTTP \(http.statusCode) from \(url.host ?? ""): \(text)")
        }
        return data
    }
}
