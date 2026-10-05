import Foundation

public enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case whisperCpp, apple, elevenLabs, openAI, groq, alibaba
    public var id: String { rawValue }

    public var defaultModel: String {
        switch self {
        case .whisperCpp, .apple: return ""
        case .elevenLabs: return "scribe_v2"
        case .openAI: return "gpt-4o-mini-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        case .alibaba: return "qwen3-asr-flash-filetrans"
        }
    }

    public var needsAPIKey: Bool { isCloud }
    public var isCloud: Bool { self != .whisperCpp && self != .apple }
}

/// Where the optional summary is generated.
public enum SummaryProviderKind: String, CaseIterable, Identifiable {
    case openAI, anthropic, groq, openRouter, claudeCode, codex, opencode, ollama, custom
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .ollama: return "Ollama"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    /// Runs on a server the user controls, usually on this Mac: Ollama or an OpenAI-compatible one.
    public var isLocal: Bool { self == .ollama || self == .custom }

    /// Hint for the address field.
    public var baseURLPlaceholder: String { self == .ollama ? LocalLLM.ollamaDefaultBase : "http://localhost:1234/v1" }

    /// Base of the OpenAI-style `/chat/completions` endpoint, nil for Anthropic, CLIs and a custom server without an address.
    /// - Parameter baseURL: the local server address as typed, empty when unset.
    public func chatCompletionsBase(baseURL: String) -> String? {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .ollama: return LocalLLM.ollamaChatBase(baseURL)
        case .custom: return LocalLLM.customChatBase(baseURL)
        case .anthropic, .claudeCode, .codex, .opencode: return nil
        }
    }

    /// A quick GET that answers whenever the local server is running.
    public func probeURL(baseURL: String) -> URL? {
        switch self {
        case .ollama: return LocalLLM.ollamaTagsURL(baseURL)
        case .custom: return LocalLLM.customModelsURL(baseURL)
        default: return nil
        }
    }

    /// The command-line tool behind it, nil for HTTP APIs.
    public var cli: CLITool? {
        switch self {
        case .claudeCode: return .claude
        case .codex: return .codex
        case .opencode: return .opencode
        default: return nil
        }
    }

    /// Empty when there is no sensible default to offer.
    public var defaultModel: String {
        switch self {
        case .openAI: return "gpt-5-mini"
        case .anthropic: return "claude-sonnet-5"
        case .groq: return "openai/gpt-oss-120b"
        case .openRouter, .claudeCode, .codex, .opencode, .ollama, .custom: return ""
        }
    }

    /// True when an empty model can't be sent.
    public var requiresModel: Bool { self == .openRouter || isLocal }

    /// Shown in the model field when it's empty.
    public var modelPlaceholder: String {
        if !defaultModel.isEmpty { return defaultModel }
        return cli == nil ? "Required" : "CLI default"
    }

    /// What an empty model means and what to type, for providers without a default.
    public var modelHint: String? {
        switch self {
        case .openRouter: return "Required, as provider/model."
        case .claudeCode: return "Empty uses the CLI default."
        case .codex: return "Empty uses ~/.codex/config.toml."
        case .opencode: return "provider/model; empty uses the CLI default."
        case .ollama: return "Required, as listed by ollama list."
        case .custom: return "Required, as the server names it."
        default: return nil
        }
    }

    /// Keychain account of the API key. OpenAI and Groq share the transcription keys.
    public var keyAccount: String {
        switch self {
        case .openAI: return ProviderKind.openAI.rawValue
        case .anthropic: return "anthropic"
        case .groq: return ProviderKind.groq.rawValue
        case .openRouter: return "openrouter"
        case .claudeCode, .codex, .opencode, .ollama, .custom: return rawValue
        }
    }

    /// Tokens of transcript a chat sends at most, kept well under the model's context.
    public var chatContextTokens: Int {
        switch self {
        case .openAI: return 120_000
        case .anthropic: return 150_000
        case .groq, .openRouter: return 100_000
        // Local models usually run with a smaller context.
        case .ollama, .custom: return 32_000
        case .claudeCode, .codex, .opencode: return 0
        }
    }

    /// True when the key is entered with the summary settings, not shared with transcription.
    public var hasOwnKey: Bool { self == .anthropic || self == .openRouter || self == .custom }
}
