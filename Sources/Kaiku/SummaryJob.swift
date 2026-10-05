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
            throw ProviderError(message: "\(problem) Check Settings > AI > Summaries.")
        }
        let model = AppSettings.summaryModel(for: kind)
        try await CallSummary.write(folder: folder, transcript: transcript, template: AppSettings.summaryPrompt,
                                    modelLabel: "\(kind.displayName) (\(model))") { prompt in
            try await complete(kind: kind, model: model, prompt: prompt)
        }
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
        return try await LLMEndpoint(kind).complete(model: model, prompt: prompt, maxTokens: maxTokens, timeout: timeout)
    }
}

extension LLMEndpoint {
    /// The HTTP API behind a summary provider; throws for command-line tools and a server without an address.
    init(_ kind: SummaryProviderKind) throws {
        let key = kind.apiKey ?? ""
        switch kind {
        case .anthropic:
            self.init(name: kind.displayName, style: .anthropic, apiKey: key)
        case .openAI, .groq, .openRouter, .ollama, .custom:
            guard let base = kind.chatCompletionsBase else { throw ProviderError(message: "No \(kind.displayName) server address yet.") }
            self.init(name: kind.displayName, style: .chatCompletions(base: base), apiKey: key, streamFallback: kind == .openAI)
        case .claudeCode, .codex, .opencode:
            throw ProviderError(message: "\(kind.displayName) runs as a command-line tool.")
        }
    }
}
