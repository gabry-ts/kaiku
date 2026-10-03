import Foundation
import KaikuCore

/// A service Kaiku signs in to: a cloud API with a key, a server on the network, a
/// command-line tool, or an app. Every key, address and tool path is entered in
/// Settings > Accounts; the other panes only pick a provider and model.
enum AccountService: String, CaseIterable, Identifiable {
    case openAI, anthropic, groq, openRouter, elevenLabs, alibaba
    case ollama, custom
    case claudeCode, codex, opencode
    case linear

    var id: String { rawValue }

    /// The Settings anchor of the service's row in Accounts.
    var anchor: String { rawValue }

    enum Group: CaseIterable {
        case cloud, network, cli, apps
    }

    var group: Group {
        switch self {
        case .openAI, .anthropic, .groq, .openRouter, .elevenLabs, .alibaba: return .cloud
        case .ollama, .custom: return .network
        case .claudeCode, .codex, .opencode: return .cli
        case .linear: return .apps
        }
    }

    static func all(in group: Group) -> [AccountService] { allCases.filter { $0.group == group } }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .elevenLabs: return "ElevenLabs"
        case .alibaba: return "Alibaba Cloud"
        case .ollama: return "Ollama"
        case .custom: return "Custom (OpenAI-compatible)"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .linear: return "Linear"
        }
    }

    /// Keychain account of the key, nil for services without one.
    var keyAccount: String? {
        switch self {
        case .openAI: return ProviderKind.openAI.rawValue
        case .groq: return ProviderKind.groq.rawValue
        case .elevenLabs: return ProviderKind.elevenLabs.rawValue
        case .alibaba: return ProviderKind.alibaba.rawValue
        case .anthropic: return SummaryProviderKind.anthropic.keyAccount
        case .openRouter: return SummaryProviderKind.openRouter.keyAccount
        case .custom: return SummaryProviderKind.custom.keyAccount
        case .linear: return LinearAPI.keyAccount
        case .ollama, .claudeCode, .codex, .opencode: return nil
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .linear: return "lin_api_…"
        case .custom: return "Optional"
        default: return "Paste your key"
        }
    }

    var keyURL: URL? {
        switch self {
        case .openAI: return ProviderKind.openAI.keyURL
        case .groq: return ProviderKind.groq.keyURL
        case .elevenLabs: return ProviderKind.elevenLabs.keyURL
        case .alibaba: return ProviderKind.alibaba.keyURL
        case .anthropic: return SummaryProviderKind.anthropic.keyURL
        case .openRouter: return SummaryProviderKind.openRouter.keyURL
        case .linear: return URL(string: "https://linear.app/settings/account/security")
        case .ollama, .custom, .claudeCode, .codex, .opencode: return nil
        }
    }

    /// The command-line tool behind it.
    var cli: CLITool? {
        switch self {
        case .claudeCode: return .claude
        case .codex: return .codex
        case .opencode: return .opencode
        default: return nil
        }
    }

    /// The summary provider it backs, if any.
    var summaryKind: SummaryProviderKind? {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .groq: return .groq
        case .openRouter: return .openRouter
        case .ollama: return .ollama
        case .custom: return .custom
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        case .opencode: return .opencode
        case .elevenLabs, .alibaba, .linear: return nil
        }
    }

    /// The transcription provider it backs, if any.
    var transcriptionKind: ProviderKind? {
        switch self {
        case .openAI: return .openAI
        case .groq: return .groq
        case .elevenLabs: return .elevenLabs
        case .alibaba: return .alibaba
        default: return nil
        }
    }

    /// The saved key, trimmed; nil when there is none.
    var key: String? {
        guard let keyAccount, let v = Keychain.get(keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !v.isEmpty else { return nil }
        return v
    }

    /// Why the key couldn't be read, when the Keychain failed.
    var keychainError: String? { keyAccount.flatMap { Keychain.errors[$0] } }

    /// Set up enough to be used: a key, an address, or a tool that was found.
    var isSetUp: Bool {
        switch self {
        case .ollama: return true
        case .custom: return LocalLLM.customChatBase(SummaryProviderKind.custom.baseURL) != nil
        case .claudeCode, .codex, .opencode: return cli.map { CLIProviders.locate($0) != nil } ?? false
        default: return key != nil
        }
    }

    /// What uses the service with the current choices, like "Transcription · Summaries".
    var usedBy: [String] {
        var uses: [String] = []
        if let p = transcriptionKind, AppSettings.provider == p { uses.append("Transcription") }
        if AppSettings.liveEnabled, let engine = AppSettings.liveEngine, let p = transcriptionKind, engine.keyProvider == p {
            uses.append("Live")
        }
        if let kind = summaryKind {
            if AppSettings.summaryEnabled && AppSettings.summaryProvider == kind { uses.append("Summaries") }
            if AppSettings.liveAssistEnabled && AppSettings.liveProvider == kind { uses.append("Live Assist") }
            if AppSettings.chatProvider == kind { uses.append("Chat") }
        }
        if self == .linear, !(AppSettings.defaults.string(forKey: Keys.linearTeamID) ?? "").isEmpty { uses.append("Action Items") }
        return uses
    }

    static func of(_ kind: SummaryProviderKind) -> AccountService {
        switch kind {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .groq: return .groq
        case .openRouter: return .openRouter
        case .ollama: return .ollama
        case .custom: return .custom
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        case .opencode: return .opencode
        }
    }

    static func of(_ kind: ProviderKind) -> AccountService? {
        switch kind {
        case .openAI: return .openAI
        case .groq: return .groq
        case .elevenLabs: return .elevenLabs
        case .alibaba: return .alibaba
        case .whisperCpp, .apple: return nil
        }
    }
}

/// Checks a key with the cheapest authenticated request each service offers.
enum KeyTester {
    /// True when the service has a request to test with.
    static func canTest(_ service: AccountService) -> Bool {
        switch service {
        case .openAI, .anthropic, .groq, .openRouter, .elevenLabs, .linear, .ollama, .custom: return true
        case .alibaba, .claudeCode, .codex, .opencode: return false
        }
    }

    static func test(_ service: AccountService) async -> (ok: Bool, message: String) {
        let key = service.key ?? ""
        var request: URLRequest
        switch service {
        case .openAI:
            request = get("https://api.openai.com/v1/models", bearer: key)
        case .groq:
            request = get("https://api.groq.com/openai/v1/models", bearer: key)
        case .openRouter:
            request = get("https://openrouter.ai/api/v1/key", bearer: key)
        case .anthropic:
            request = get("https://api.anthropic.com/v1/models", bearer: nil)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .elevenLabs:
            request = get("https://api.elevenlabs.io/v1/user", bearer: nil)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .linear:
            request = URLRequest(url: ActionItems.linearEndpoint, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "Authorization")
            request.httpBody = Data(#"{"query":"{ viewer { organization { name } } }"}"#.utf8)
        case .ollama:
            guard let url = SummaryProviderKind.ollama.probeURL else { return (false, "Check the server address.") }
            request = URLRequest(url: url, timeoutInterval: 5)
        case .custom:
            guard let url = SummaryProviderKind.custom.probeURL else { return (false, "Add the server address first.") }
            request = URLRequest(url: url, timeoutInterval: 5)
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .alibaba, .claudeCode, .codex, .opencode:
            return (false, "Nothing to test.")
        }
        if service.keyAccount != nil, service != .custom, key.isEmpty { return (false, "Add a key first.") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                if service == .linear {
                    if let org = linearOrganization(data) { return (true, "Connected to \(org)") }
                    return (false, "Linear refused the key.")
                }
                return (true, service.group == .network ? "The server answered." : "The key works.")
            case 401, 403:
                return (false, "\(service.displayName) refused the key (HTTP \(status)).")
            default:
                return (false, "\(service.displayName) answered HTTP \(status).")
            }
        } catch {
            return (false, service.group == .network ? "Not running at this address." : error.localizedDescription)
        }
    }

    private static func get(_ url: String, bearer: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The organization name in Linear's answer to the viewer query; nil when it reports errors.
    private static func linearOrganization(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["errors"] == nil,
              let viewer = (json["data"] as? [String: Any])?["viewer"] as? [String: Any],
              let org = viewer["organization"] as? [String: Any] else { return nil }
        return org["name"] as? String ?? "Linear"
    }
}
