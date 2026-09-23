import Foundation
import McRofoneCore
import Security

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case whisperCpp, elevenLabs, openAI, groq
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperCpp: return "whisper.cpp (local)"
        case .elevenLabs: return "ElevenLabs Scribe"
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        }
    }

    var defaultModel: String {
        switch self {
        case .whisperCpp: return ""
        case .elevenLabs: return "scribe_v2"
        case .openAI: return "gpt-4o-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        }
    }

    var needsAPIKey: Bool { self != .whisperCpp }
    var isCloud: Bool { self != .whisperCpp }
}

/// Where the optional summary is generated.
enum SummaryProviderKind: String, CaseIterable, Identifiable {
    case openAI, anthropic, groq
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .groq: return "Groq"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-5-mini"
        case .anthropic: return "claude-sonnet-5"
        case .groq: return "openai/gpt-oss-120b"
        }
    }

    /// Keychain account of the API key. OpenAI and Groq share the transcription keys.
    var keyAccount: String {
        switch self {
        case .openAI: return ProviderKind.openAI.rawValue
        case .anthropic: return "anthropic"
        case .groq: return ProviderKind.groq.rawValue
        }
    }

    var keyURL: URL? {
        switch self {
        case .openAI: return ProviderKind.openAI.keyURL
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .groq: return ProviderKind.groq.keyURL
        }
    }

    var apiKey: String? {
        guard let v = Keychain.get(keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}

/// When silence is cut before transcription.
enum TrimSilenceMode: String, CaseIterable, Identifiable {
    case off, cloud, always
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Never"
        case .cloud: return "Cloud providers only"
        case .always: return "Always"
        }
    }
}

/// UserDefaults keys. Views bind to these with @AppStorage.
enum Keys {
    static let baseFolder = "baseFolder"
    static let provider = "provider"
    static let language = "language"
    static let meLabel = "meLabel"
    static let othersLabel = "othersLabel"
    static let whisperPath = "whisperPath"
    static let whisperModel = "whisperModel"
    static let ffmpegPath = "ffmpegPath"
    static let microphone = "microphone"
    static let hotKey = "hotKey"
    static let systemAudioVerified = "systemAudioVerified"
    static let onboardingDone = "onboardingDone"
    static let webhookEnabled = "webhookEnabled"
    static let webhookURL = "webhookURL"
    static let webhookMethod = "webhookMethod"
    static let webhookHeaderKeys = "webhookHeaderKeys"
    static let webhookBodyMode = "webhookBodyMode"
    static let webhookTemplate = "webhookTemplate"
    static let webhookContentType = "webhookContentType"
    static let notificationsEnabled = "notificationsEnabled"
    static let lastRecordingFolder = "lastRecordingFolder"
    static let bookmarkHotKey = "bookmarkHotKey"
    static let pauseHotKey = "pauseHotKey"
    static let trimSilence = "trimSilence"
    static let trimThresholdDB = "trimThresholdDB"
    static let trimMinSilence = "trimMinSilence"
    static let pricesPerHour = "pricesPerHour"
    static let autoCleanupEnabled = "autoCleanupEnabled"
    static let autoCleanupDays = "autoCleanupDays"
    static let lastAutoCleanup = "lastAutoCleanup"
    static let detectCalls = "detectCalls"
    static let detectDisabledApps = "detectDisabledApps"
    static let detectAutoStart = "detectAutoStart"
    static let detectEndNotify = "detectEndNotify"
    static let detectAutoStopSeconds = "detectAutoStopSeconds"
    static let calendarEnabled = "calendarEnabled"
    static let calendarIDs = "calendarIDs"
    static let summaryEnabled = "summaryEnabled"
    static let summaryProvider = "summaryProvider"
    static let summaryPrompt = "summaryPrompt"
    static let lastTags = "lastTags"
    static let removeEcho = "removeEcho"
    static func model(_ p: ProviderKind) -> String { "model.\(p.rawValue)" }
    static func summaryModel(_ p: SummaryProviderKind) -> String { "summaryModel.\(p.rawValue)" }
}

enum AppSettings {
    /// Swappable so snapshot rendering never touches the real preferences.
    static var defaults: UserDefaults = .standard

    static func registerDefaults() {
        defaults.register(defaults: [
            Keys.baseFolder: defaultBaseFolder.path,
            Keys.provider: ProviderKind.whisperCpp.rawValue,
            Keys.language: "auto",
            Keys.meLabel: "Me",
            Keys.othersLabel: "Others",
            Keys.whisperPath: "/opt/homebrew/bin/whisper-cli",
            Keys.whisperModel: NSHomeDirectory() + "/Library/Application Support/mc.Rofone/models/ggml-large-v3-turbo.bin",
            Keys.ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            Keys.microphone: AudioDevices.automatic,
            Keys.hotKey: "ctrlOptCmdR",
            Keys.systemAudioVerified: false,
            Keys.onboardingDone: false,
            Keys.webhookEnabled: false,
            Keys.webhookURL: "",
            Keys.webhookMethod: "POST",
            Keys.webhookHeaderKeys: [String](),
            Keys.webhookBodyMode: "default",
            Keys.webhookTemplate: "{\n  \"title\": \"{{title}}\",\n  \"text\": \"{{transcript_markdown}}\"\n}",
            Keys.webhookContentType: "application/json",
            Keys.notificationsEnabled: true,
            Keys.model(.elevenLabs): ProviderKind.elevenLabs.defaultModel,
            Keys.model(.openAI): ProviderKind.openAI.defaultModel,
            Keys.model(.groq): ProviderKind.groq.defaultModel,
            Keys.bookmarkHotKey: ModifierPreset.ctrlOptCmd.rawValue,
            Keys.pauseHotKey: ModifierPreset.ctrlOptCmd.rawValue,
            Keys.trimSilence: TrimSilenceMode.cloud.rawValue,
            Keys.trimThresholdDB: -45.0,
            Keys.trimMinSilence: 2.0,
            Keys.autoCleanupEnabled: false,
            Keys.autoCleanupDays: 30,
            Keys.detectCalls: true,
            Keys.detectDisabledApps: [String](),
            Keys.detectAutoStart: false,
            Keys.detectEndNotify: true,
            Keys.detectAutoStopSeconds: 0,
            Keys.calendarEnabled: true,
            Keys.calendarIDs: [String](),
            Keys.removeEcho: true,
            Keys.summaryEnabled: false,
            Keys.summaryProvider: SummaryProviderKind.openAI.rawValue,
            Keys.summaryPrompt: SummaryAPI.defaultPrompt,
            Keys.summaryModel(.openAI): SummaryProviderKind.openAI.defaultModel,
            Keys.summaryModel(.anthropic): SummaryProviderKind.anthropic.defaultModel,
            Keys.summaryModel(.groq): SummaryProviderKind.groq.defaultModel,
        ])
    }

    static var defaultBaseFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/mc.Rofone", isDirectory: true)
    }

    static var baseFolder: URL {
        let path = defaults.string(forKey: Keys.baseFolder) ?? ""
        return path.isEmpty ? defaultBaseFolder : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var provider: ProviderKind {
        ProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .whisperCpp
    }

    /// "auto" or an ISO language code.
    static var language: String { normalizedLanguage(defaults.string(forKey: Keys.language)) }

    static func normalizedLanguage(_ raw: String?) -> String {
        let v = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return v.isEmpty ? "auto" : v
    }

    static var meLabel: String { nonEmpty(defaults.string(forKey: Keys.meLabel), "Me") }
    static var othersLabel: String { nonEmpty(defaults.string(forKey: Keys.othersLabel), "Others") }
    static var whisperPath: String { expand(defaults.string(forKey: Keys.whisperPath)) }
    static var whisperModel: String { expand(defaults.string(forKey: Keys.whisperModel)) }
    static var ffmpegPath: String { nonEmpty(expand(defaults.string(forKey: Keys.ffmpegPath)), "/opt/homebrew/bin/ffmpeg") }
    /// "auto", "none" or a Core Audio device UID.
    static var microphone: String { defaults.string(forKey: Keys.microphone) ?? AudioDevices.automatic }
    static var webhookEnabled: Bool { defaults.bool(forKey: Keys.webhookEnabled) }
    static var webhookURL: String { defaults.string(forKey: Keys.webhookURL) ?? "" }
    static var webhookMethod: String { nonEmpty(defaults.string(forKey: Keys.webhookMethod), "POST") }
    static var webhookUsesTemplate: Bool { defaults.string(forKey: Keys.webhookBodyMode) == "template" }
    static var webhookTemplate: String { defaults.string(forKey: Keys.webhookTemplate) ?? "" }
    static var webhookContentType: String { nonEmpty(defaults.string(forKey: Keys.webhookContentType), "application/json") }

    /// Custom webhook headers: names in UserDefaults, values in the Keychain.
    static var webhookHeaders: [(name: String, value: String)] {
        get {
            let names = defaults.stringArray(forKey: Keys.webhookHeaderKeys) ?? []
            let values = Keychain.get("webhook.headers")
                .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
            return names.map { ($0, values[$0] ?? "") }
        }
        set {
            let clean = newValue.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            defaults.set(clean.map(\.name), forKey: Keys.webhookHeaderKeys)
            let dict = Dictionary(clean.map { ($0.name, $0.value) }, uniquingKeysWith: { _, b in b })
            let json = (try? JSONEncoder().encode(dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            Keychain.set(json, for: "webhook.headers")
        }
    }

    static var notificationsEnabled: Bool { defaults.bool(forKey: Keys.notificationsEnabled) }

    static func model(for p: ProviderKind) -> String {
        nonEmpty(defaults.string(forKey: Keys.model(p)), p.defaultModel)
    }

    static func shouldTrimSilence(for p: ProviderKind) -> Bool {
        switch TrimSilenceMode(rawValue: defaults.string(forKey: Keys.trimSilence) ?? "") ?? .cloud {
        case .off: return false
        case .cloud: return p.isCloud
        case .always: return true
        }
    }

    static var trimOptions: SilenceTrimmer.Options {
        let db = defaults.double(forKey: Keys.trimThresholdDB)
        let min = defaults.double(forKey: Keys.trimMinSilence)
        return SilenceTrimmer.Options(thresholdDB: db < 0 ? db : -45, minDuration: min >= 1 ? min : 2)
    }

    /// User-edited transcription prices, USD per hour of audio, by model id.
    static var priceOverrides: [String: Double] {
        get { (defaults.dictionary(forKey: Keys.pricesPerHour) as? [String: Double]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.pricesPerHour) }
    }

    static var removeEcho: Bool { defaults.bool(forKey: Keys.removeEcho) }
    static var summaryEnabled: Bool { defaults.bool(forKey: Keys.summaryEnabled) }
    static var summaryProvider: SummaryProviderKind {
        SummaryProviderKind(rawValue: defaults.string(forKey: Keys.summaryProvider) ?? "") ?? .openAI
    }
    static func summaryModel(for p: SummaryProviderKind) -> String {
        nonEmpty(defaults.string(forKey: Keys.summaryModel(p)), p.defaultModel)
    }
    static var summaryPrompt: String { defaults.string(forKey: Keys.summaryPrompt) ?? SummaryAPI.defaultPrompt }

    static var calendarEnabled: Bool { defaults.bool(forKey: Keys.calendarEnabled) }
    /// Calendar identifiers to use; empty means all.
    static var calendarIDs: [String] { defaults.stringArray(forKey: Keys.calendarIDs) ?? [] }

    static var detectCalls: Bool { defaults.bool(forKey: Keys.detectCalls) }
    static var detectDisabledApps: [String] { defaults.stringArray(forKey: Keys.detectDisabledApps) ?? [] }
    static var detectAutoStart: Bool { defaults.bool(forKey: Keys.detectAutoStart) }
    static var detectEndNotify: Bool { defaults.bool(forKey: Keys.detectEndNotify) }
    static var detectAutoStopSeconds: Int { defaults.integer(forKey: Keys.detectAutoStopSeconds) }

    static var autoCleanupEnabled: Bool { defaults.bool(forKey: Keys.autoCleanupEnabled) }
    static var autoCleanupDays: Int { max(1, defaults.integer(forKey: Keys.autoCleanupDays)) }

    static var lastRecordingFolder: URL? {
        get { defaults.string(forKey: Keys.lastRecordingFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: Keys.lastRecordingFolder) }
    }

    private static func nonEmpty(_ v: String?, _ fallback: String) -> String {
        let t = (v ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? fallback : t
    }

    private static func expand(_ v: String?) -> String {
        ((v ?? "").trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }
}

/// Minimal Keychain wrapper for API keys (generic passwords).
enum Keychain {
    private static let service = "com.gabrielepartiti.mcrofone"

    /// When set, used instead of the real Keychain (snapshot rendering).
    static var mock: [String: String]?

    static func get(_ account: String) -> String? {
        if let mock { return mock[account] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        if mock != nil { mock?[account] = value; return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func apiKey(for p: ProviderKind) -> String? {
        guard let v = get(p.rawValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}
