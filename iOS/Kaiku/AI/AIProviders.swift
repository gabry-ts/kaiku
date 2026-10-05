import Foundation
import KaikuCore

extension SummaryProviderKind {
    /// The providers reachable over HTTP: command-line tools can't run on an iPhone.
    static let phoneProviders: [SummaryProviderKind] = [.openAI, .anthropic, .groq, .openRouter, .ollama, .custom]

    /// Address of the server as typed in Settings, empty when unset.
    var baseURL: String {
        guard isLocal else { return "" }
        return UserDefaults.standard.string(forKey: PhoneKeys.baseURL(self)) ?? ""
    }

    var apiKey: String? {
        guard self != .ollama else { return nil }
        guard let v = Keychain.get(keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    /// What is missing before it can be used, nil when ready.
    var problem: String? {
        if self == .custom { return LocalLLM.customChatBase(baseURL) == nil ? "No \(displayName) server address yet." : nil }
        if self == .ollama { return LocalLLM.normalize(baseURL).isEmpty ? "No \(displayName) server address yet." : nil }
        return apiKey == nil ? "No \(displayName) API key yet." : nil
    }
}

extension LLMEndpoint {
    /// The HTTP API behind a provider; throws when it isn't set up.
    init(_ kind: SummaryProviderKind) throws {
        if let problem = kind.problem { throw ProviderError(message: "\(problem) Check Settings > AI.") }
        let key = kind.apiKey ?? ""
        switch kind {
        case .anthropic:
            self.init(name: kind.displayName, style: .anthropic, apiKey: key)
        case .openAI, .groq, .openRouter, .ollama, .custom:
            guard let base = kind.chatCompletionsBase(baseURL: kind.baseURL) else {
                throw ProviderError(message: "No \(kind.displayName) server address yet.")
            }
            self.init(name: kind.displayName, style: .chatCompletions(base: base), apiKey: key, streamFallback: kind == .openAI)
        case .claudeCode, .codex, .opencode:
            throw ProviderError(message: "\(kind.displayName) runs as a command-line tool, which isn't available on iPhone.")
        }
    }
}

/// Writes summary.md for a call with the provider chosen in Settings.
enum PhoneSummary {
    static func run(folder: RecordingFolder) async throws {
        guard let transcript = try? String(contentsOf: folder.transcriptURL, encoding: .utf8) else {
            throw ProviderError(message: "This call has no transcript yet.")
        }
        let kind = PhoneSettings.summaryProvider
        let endpoint = try LLMEndpoint(kind)
        let model = PhoneSettings.summaryModel(for: kind)
        if kind.requiresModel, model.isEmpty { throw ProviderError(message: "\(kind.displayName) needs a model. Check Settings > AI.") }
        try await CallSummary.write(folder: folder, transcript: transcript, template: SummaryAPI.defaultPrompt,
                                    modelLabel: "\(kind.displayName) (\(model))") { prompt in
            try await endpoint.complete(model: model, prompt: prompt)
        }
    }
}
