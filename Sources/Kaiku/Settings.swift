import Foundation
import KaikuCore
import PartitiUI
import Security

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case whisperCpp, apple, elevenLabs, openAI, groq, alibaba
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperCpp: return "whisper.cpp (local)"
        case .apple: return "Apple (on this Mac)"
        case .elevenLabs: return "ElevenLabs Scribe"
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .alibaba: return "Alibaba Cloud"
        }
    }

    var defaultModel: String {
        switch self {
        case .whisperCpp, .apple: return ""
        case .elevenLabs: return "scribe_v2"
        case .openAI: return "gpt-4o-mini-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        case .alibaba: return "qwen3-asr-flash-filetrans"
        }
    }

    var needsAPIKey: Bool { isCloud }
    var isCloud: Bool { self != .whisperCpp && self != .apple }

    /// The providers that can run on this version of macOS.
    static var available: [ProviderKind] {
        allCases.filter(\.isAvailable)
    }

    /// The system speech recognizer needs macOS 26.
    var isAvailable: Bool {
        guard self == .apple else { return true }
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// Where the optional summary is generated.
enum SummaryProviderKind: String, CaseIterable, Identifiable {
    case openAI, anthropic, groq, openRouter, claudeCode, codex, opencode, ollama, custom
    var id: String { rawValue }

    var displayName: String {
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
    var isLocal: Bool { self == .ollama || self == .custom }

    /// Address of the local server as typed in Settings, empty when unset.
    var baseURL: String {
        guard isLocal else { return "" }
        return AppSettings.defaults.string(forKey: Keys.baseURL(self)) ?? ""
    }

    /// Hint for the address field.
    var baseURLPlaceholder: String { self == .ollama ? LocalLLM.ollamaDefaultBase : "http://localhost:1234/v1" }

    /// Base of the OpenAI-style `/chat/completions` endpoint, nil for Anthropic, CLIs and a custom server without an address.
    var chatCompletionsBase: String? {
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
    var probeURL: URL? {
        switch self {
        case .ollama: return LocalLLM.ollamaTagsURL(baseURL)
        case .custom: return LocalLLM.customModelsURL(baseURL)
        default: return nil
        }
    }

    /// The command-line tool behind it, nil for HTTP APIs.
    var cli: CLITool? {
        switch self {
        case .claudeCode: return .claude
        case .codex: return .codex
        case .opencode: return .opencode
        default: return nil
        }
    }

    /// Empty when there is no sensible default to offer.
    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-5-mini"
        case .anthropic: return "claude-sonnet-5"
        case .groq: return "openai/gpt-oss-120b"
        case .openRouter, .claudeCode, .codex, .opencode, .ollama, .custom: return ""
        }
    }

    /// True when an empty model can't be sent.
    var requiresModel: Bool { self == .openRouter || isLocal }

    /// Shown in the model field when it's empty.
    var modelPlaceholder: String {
        if !defaultModel.isEmpty { return defaultModel }
        return cli == nil ? "Required" : "CLI default"
    }

    /// What an empty model means and what to type, for providers without a default.
    var modelHint: String? {
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

    /// True when the model menu has names to offer.
    var listsModels: Bool { self == .openRouter || self == .claudeCode || self == .opencode || self == .ollama }

    /// Keychain account of the API key. OpenAI and Groq share the transcription keys.
    var keyAccount: String {
        switch self {
        case .openAI: return ProviderKind.openAI.rawValue
        case .anthropic: return "anthropic"
        case .groq: return ProviderKind.groq.rawValue
        case .openRouter: return "openrouter"
        case .claudeCode, .codex, .opencode, .ollama, .custom: return rawValue
        }
    }

    /// Tokens of transcript a chat sends at most, kept well under the model's context.
    var chatContextTokens: Int {
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
    var hasOwnKey: Bool { self == .anthropic || self == .openRouter || self == .custom }

    var keyURL: URL? {
        switch self {
        case .openAI: return ProviderKind.openAI.keyURL
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .groq: return ProviderKind.groq.keyURL
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .claudeCode, .codex, .opencode, .ollama, .custom: return nil
        }
    }

    var apiKey: String? {
        guard cli == nil, self != .ollama else { return nil }
        guard let v = Keychain.get(keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    /// What is missing before it can be used, nil when ready.
    var problem: String? {
        if let cli { return CLIProviders.locate(cli) == nil ? "\(displayName) CLI not found." : nil }
        if self == .custom { return LocalLLM.customChatBase(baseURL) == nil ? "No \(displayName) server address yet." : nil }
        if self == .ollama { return nil }
        return apiKey == nil ? "No \(displayName) API key yet." : nil
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

/// Alibaba Cloud Model Studio region. API keys are issued per region.
enum AlibabaRegion: String, CaseIterable, Identifiable {
    case singapore, beijing
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .singapore: return "Singapore (international)"
        case .beijing: return "Beijing (China)"
        }
    }

    var host: String {
        switch self {
        case .singapore: return "dashscope-intl.aliyuncs.com"
        case .beijing: return "dashscope.aliyuncs.com"
        }
    }
}

/// The text sizes the library offers for reading transcripts and summaries, in points.
enum ReadingSize {
    static let steps: [Double] = [15, 17, 19.5, 22.5, 26]
    static let standard: Double = 19.5

    static func larger(than size: Double) -> Double { steps.first { $0 > size + 0.01 } ?? steps[steps.count - 1] }
    static func smaller(than size: Double) -> Double { steps.last { $0 < size - 0.01 } ?? steps[0] }
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
    static let microphone = "microphone"
    static let followCallMicrophone = "followCallMicrophone"
    /// Shortcut presets used before shortcuts could be recorded (read once to migrate).
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
    /// The one notifications switch used before each kind had its own (read to carry it over).
    static let notificationsEnabled = "notificationsEnabled"
    static let lastRecordingFolder = "lastRecordingFolder"
    static let bookmarkHotKey = "bookmarkHotKey"
    static let pauseHotKey = "pauseHotKey"
    static let trimSilence = "trimSilence"
    static let muteStyle = "muteStyle"
    /// The old switch for the Dock icon, no longer read: Kaiku is in the Dock while its window is open.
    static let showInDock = "showInDock"
    /// Model file for live whisper; empty picks a light one.
    static let liveWhisperModel = "liveWhisperModel"
    static let muteVolumePercent = "muteVolumePercent"
    static let trimThresholdDB = "trimThresholdDB"
    static let trimMinSilence = "trimMinSilence"
    static let pricesPerHour = "pricesPerHour"
    static let autoCleanupEnabled = "autoCleanupEnabled"
    static let autoCleanupDays = "autoCleanupDays"
    static let lastAutoCleanup = "lastAutoCleanup"
    static let detectCalls = "detectCalls"
    static let detectDisabledApps = "detectDisabledApps"
    /// The old "start recording automatically" switch (read once to migrate to `autoRecordMode`).
    static let detectAutoStart = "detectAutoStart"
    static let autoRecordMode = "autoRecordMode"
    /// "Ask to stop when the call ends", before notifications had their own switches
    /// (read to carry it over).
    static let detectEndNotify = "detectEndNotify"
    static let detectAutoStopSeconds = "detectAutoStopSeconds"
    static let detectCallEndMode = "detectCallEndMode"
    static let stopAfterSilenceSeconds = "stopAfterSilenceSeconds"
    static let maxRecordingSeconds = "maxRecordingSeconds"
    static let detectSourceRules = "detectSourceRules"
    static let detectSeenSources = "detectSeenSources"
    static let detectCustomApps = "detectCustomApps"
    static let detectCustomWebsites = "detectCustomWebsites"
    static let detectRemovedSources = "detectRemovedSources"
    static let sourceRulesMigrated = "sourceRulesMigrated"
    static let accessibilityAsked = "accessibilityAsked"
    static let calendarEnabled = "calendarEnabled"
    static let calendarIDs = "calendarIDs"
    static let summaryEnabled = "summaryEnabled"
    static let summaryProvider = "summaryProvider"
    static let summaryPrompt = "summaryPrompt"
    /// Where action items go: the Reminders list and the Linear team and project (ids).
    static let remindersListID = "remindersListID"
    static let linearTeamID = "linearTeamID"
    static let linearProjectID = "linearProjectID"
    static let lastTags = "lastTags"
    static let removeEcho = "removeEcho"
    static let popoverSections = "popoverSections"
    static let popoverRecentCount = "popoverRecentCount"
    static let liveEnabled = "liveEnabled"
    static let liveEngine = "liveEngine"
    static let liveAfterCall = "liveAfterCall"
    static let alibabaRegion = "alibabaRegion"
    static let liveAssistEnabled = "liveAssistEnabled"
    /// Provider of the live Summary and Ask tabs; unset uses the summary provider.
    static let liveProvider = "liveProvider"
    /// Provider of the library chat; unset uses the summary provider.
    static let chatProvider = "chatProvider"
    /// Set once Smart search was turned on, so new transcriptions are indexed.
    static let smartSearchUsed = "smartSearchUsed"
    /// Lets agents change calls through kaiku-mcp; reading is always allowed.
    static let agentsAllowEdits = KaikuAgents.allowEditsKey
    /// Point size of the transcript and summary text in the library.
    static let readingTextSize = "readingTextSize"
    /// Address of the Ollama or custom server.
    static func baseURL(_ p: SummaryProviderKind) -> String { "baseURL.\(p.rawValue)" }
    static func model(_ p: ProviderKind) -> String { "model.\(p.rawValue)" }
    static func summaryModel(_ p: SummaryProviderKind) -> String { "summaryModel.\(p.rawValue)" }
    static func liveSummaryModel(_ p: SummaryProviderKind) -> String { "liveSummaryModel.\(p.rawValue)" }
    static func liveAskModel(_ p: SummaryProviderKind) -> String { "liveAskModel.\(p.rawValue)" }
    static func chatModel(_ p: SummaryProviderKind) -> String { "chatModel.\(p.rawValue)" }
    static func cliPath(_ t: CLITool) -> String { "cliPath.\(t.rawValue)" }
    static func cliDetected(_ t: CLITool) -> String { "cliDetected.\(t.rawValue)" }
}

enum AppSettings {
    /// Swappable so snapshot rendering never touches the real preferences.
    static var defaults: UserDefaults = .standard

    static func registerDefaults() {
        // Read before registering anything: only what was really saved carries over.
        let legacyInformational = defaults.object(forKey: Keys.notificationsEnabled) as? Bool
        let legacyCallEnded = defaults.object(forKey: Keys.detectEndNotify) as? Bool
        for kind in NotificationKind.allCases {
            defaults.register(defaults: [
                kind.showKey: kind.defaultShown(legacyInformational: legacyInformational, legacyCallEnded: legacyCallEnded),
                kind.soundKey: kind.defaultSound,
            ])
        }
        defaults.register(defaults: [
            Keys.baseFolder: defaultBaseFolder.path,
            Keys.provider: ProviderKind.whisperCpp.rawValue,
            Keys.language: "auto",
            Keys.meLabel: "Me",
            Keys.othersLabel: "Others",
            Keys.whisperPath: "",
            Keys.whisperModel: NSHomeDirectory() + "/Library/Application Support/Kaiku/models/ggml-large-v3-turbo.bin",
            Keys.microphone: AudioDevices.automatic,
            Keys.followCallMicrophone: true,
            Keys.systemAudioVerified: false,
            Keys.onboardingDone: false,
            Keys.webhookEnabled: false,
            Keys.webhookURL: "",
            Keys.webhookMethod: "POST",
            Keys.webhookHeaderKeys: [String](),
            Keys.webhookBodyMode: "default",
            Keys.webhookTemplate: "{\n  \"title\": \"{{title}}\",\n  \"text\": \"{{transcript_markdown}}\"\n}",
            Keys.webhookContentType: "application/json",
            Keys.model(.elevenLabs): ProviderKind.elevenLabs.defaultModel,
            Keys.model(.openAI): ProviderKind.openAI.defaultModel,
            Keys.model(.groq): ProviderKind.groq.defaultModel,
            Keys.model(.alibaba): ProviderKind.alibaba.defaultModel,
            Keys.alibabaRegion: AlibabaRegion.singapore.rawValue,
            Keys.trimSilence: TrimSilenceMode.cloud.rawValue,
            Keys.muteStyle: MuteStyle.volume.rawValue,
            Keys.muteVolumePercent: 1,
            Keys.trimThresholdDB: -45.0,
            Keys.trimMinSilence: 2.0,
            Keys.autoCleanupEnabled: false,
            Keys.autoCleanupDays: 30,
            Keys.detectCalls: true,
            Keys.detectDisabledApps: [String](),
            Keys.detectAutoStopSeconds: 120,
            Keys.detectCallEndMode: CallEndMode.standard.rawValue,
            Keys.stopAfterSilenceSeconds: 900,
            Keys.maxRecordingSeconds: 14400,
            Keys.calendarEnabled: true,
            Keys.calendarIDs: [String](),
            Keys.removeEcho: true,
            Keys.popoverRecentCount: PopoverLayout.defaultRecentCount,
            Keys.liveEnabled: false,
            Keys.liveEngine: LiveEngineKind.apple.rawValue,
            Keys.liveAfterCall: LiveAfterCall.preview.rawValue,
            Keys.summaryEnabled: false,
            Keys.summaryProvider: SummaryProviderKind.openAI.rawValue,
            Keys.summaryPrompt: SummaryAPI.defaultPrompt,
            Keys.summaryModel(.openAI): SummaryProviderKind.openAI.defaultModel,
            Keys.summaryModel(.anthropic): SummaryProviderKind.anthropic.defaultModel,
            Keys.summaryModel(.groq): SummaryProviderKind.groq.defaultModel,
            Keys.baseURL(.ollama): LocalLLM.ollamaDefaultBase,
            Keys.liveAssistEnabled: false,
            Keys.agentsAllowEdits: false,
            Keys.readingTextSize: ReadingSize.standard,
        ])
        for p in SummaryProviderKind.allCases {
            defaults.register(defaults: [Keys.liveSummaryModel(p): p.defaultModel, Keys.liveAskModel(p): p.defaultModel,
                                         Keys.chatModel(p): p.defaultModel])
        }
    }

    static var defaultBaseFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Kaiku", isDirectory: true)
    }

    /// Shown instead of the real path when rendering snapshots from temporary fixtures.
    static var displayBaseFolderOverride: String?

    /// Base folder for display, with the home folder abbreviated to `~`.
    static var baseFolderDisplayPath: String {
        displayBaseFolderOverride ?? (baseFolder.path as NSString).abbreviatingWithTildeInPath
    }

    static var baseFolder: URL {
        let path = defaults.string(forKey: Keys.baseFolder) ?? ""
        return path.isEmpty ? defaultBaseFolder : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The chosen provider; whisper.cpp when nothing is saved or the saved one can't run here.
    static var provider: ProviderKind { provider(saved: defaults.string(forKey: Keys.provider)) }

    static func provider(saved: String?) -> ProviderKind {
        ProviderKind(rawValue: saved ?? "").flatMap { $0.isAvailable ? $0 : nil } ?? .whisperCpp
    }

    /// "auto" or an ISO language code.
    static var language: String { normalizedLanguage(defaults.string(forKey: Keys.language)) }

    static func normalizedLanguage(_ raw: String?) -> String {
        let v = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return v.isEmpty ? "auto" : v
    }

    static var meLabel: String { nonEmpty(defaults.string(forKey: Keys.meLabel), "Me") }
    static var othersLabel: String { nonEmpty(defaults.string(forKey: Keys.othersLabel), "Others") }
    /// The user's whisper-cli if set and executable, otherwise the bundled one (or Homebrew's).
    static var whisperPath: String {
        let custom = expand(defaults.string(forKey: Keys.whisperPath))
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) { return custom }
        return WhisperModels.detectWhisperCLI() ?? custom
    }
    static var whisperModel: String { expand(defaults.string(forKey: Keys.whisperModel)) }
    /// The model for live whisper: the one chosen in Settings > Live, else Small or Base
    /// when downloaded (light enough to run all call long), else the transcription model.
    static var liveWhisperModel: String {
        let chosen = expand(defaults.string(forKey: Keys.liveWhisperModel))
        if !chosen.isEmpty, FileManager.default.fileExists(atPath: chosen) { return chosen }
        let light = ["ggml-small.bin", "ggml-base.bin"].map { WhisperModels.directory.appendingPathComponent($0).path }
        return light.first { FileManager.default.fileExists(atPath: $0) } ?? whisperModel
    }
    /// "auto", "none" or a Core Audio device UID.
    static var microphone: String { defaults.string(forKey: Keys.microphone) ?? AudioDevices.automatic }
    /// In automatic mode, record from the microphone the call app uses, and follow it.
    static var followCallMicrophone: Bool {
        (microphone == AudioDevices.automatic || microphone.isEmpty) && defaults.bool(forKey: Keys.followCallMicrophone)
    }
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

    /// Whether this kind of notification is posted at all.
    static func notificationShown(_ kind: NotificationKind) -> Bool { defaults.bool(forKey: kind.showKey) }
    /// Whether this kind of notification plays a sound.
    static func notificationSound(_ kind: NotificationKind) -> Bool { defaults.bool(forKey: kind.soundKey) }

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

    static var muteStyle: MuteStyle {
        MuteStyle(rawValue: defaults.string(forKey: Keys.muteStyle) ?? "") ?? .volume
    }

    /// Input volume (0...1) left on microphones muted by turning the volume down.
    static var muteVolume: Float {
        Float(min(max(defaults.integer(forKey: Keys.muteVolumePercent), 0), 10)) / 100
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

    static var alibabaRegion: AlibabaRegion {
        AlibabaRegion(rawValue: defaults.string(forKey: Keys.alibabaRegion) ?? "") ?? .singapore
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

    /// The live window's Summary and Ask tabs, with their own provider.
    static var liveAssistEnabled: Bool { liveEnabled && defaults.bool(forKey: Keys.liveAssistEnabled) }
    static var liveProvider: SummaryProviderKind {
        SummaryProviderKind(rawValue: defaults.string(forKey: Keys.liveProvider) ?? "") ?? summaryProvider
    }
    static func liveSummaryModel(for p: SummaryProviderKind) -> String {
        nonEmpty(defaults.string(forKey: Keys.liveSummaryModel(p)), p.defaultModel)
    }
    static func liveAskModel(for p: SummaryProviderKind) -> String {
        nonEmpty(defaults.string(forKey: Keys.liveAskModel(p)), p.defaultModel)
    }

    /// The library chat, with its own provider.
    static var chatProvider: SummaryProviderKind {
        SummaryProviderKind(rawValue: defaults.string(forKey: Keys.chatProvider) ?? "") ?? summaryProvider
    }
    static func chatModel(for p: SummaryProviderKind) -> String {
        nonEmpty(defaults.string(forKey: Keys.chatModel(p)), p.defaultModel)
    }
    /// Where chats are saved, one JSON file each. Not a call folder: it has no meta.json.
    static var chatsFolder: URL { baseFolder.appendingPathComponent("Chats", isDirectory: true) }

    /// Agents may rename calls, change tags and speakers, and ask for a new transcript or summary.
    static var agentsAllowEdits: Bool { defaults.bool(forKey: Keys.agentsAllowEdits) }

    static var calendarEnabled: Bool { defaults.bool(forKey: Keys.calendarEnabled) }
    /// Calendar identifiers to use; empty means all.
    static var calendarIDs: [String] { defaults.stringArray(forKey: Keys.calendarIDs) ?? [] }

    static var detectCalls: Bool { defaults.bool(forKey: Keys.detectCalls) }
    static var detectDisabledApps: [String] { defaults.stringArray(forKey: Keys.detectDisabledApps) ?? [] }
    /// When a detected call starts recording by itself; Off until chosen or migrated.
    static var autoRecordMode: AutoRecordMode {
        defaults.string(forKey: Keys.autoRecordMode).flatMap(AutoRecordMode.init(rawValue:)) ?? .off
    }
    static var detectAutoStopSeconds: Int { defaults.integer(forKey: Keys.detectAutoStopSeconds) }
    static var callEndMode: CallEndMode { CallEndMode(saved: defaults.string(forKey: Keys.detectCallEndMode)) }
    static var stopAfterSilenceSeconds: Int { defaults.integer(forKey: Keys.stopAfterSilenceSeconds) }
    static var maxRecordingSeconds: Int { defaults.integer(forKey: Keys.maxRecordingSeconds) }

    /// What happens when a call ends: the chosen mode, unless its question can't be shown.
    @MainActor static var callEndBehavior: CallEndBehavior {
        callEndMode.behavior(notificationsAllowed: Permissions.shared.notificationsAllowed,
                             callEndedNotificationEnabled: notificationShown(.callEnded))
    }

    /// Posted when the source rules or the seen sources change, so an open Sources pane reloads.
    static let sourcesChanged = Notification.Name("kaiku.sourcesChanged")

    /// Always/Never choice per call source.
    static var sourceRules: SourceRules {
        get {
            defaults.data(forKey: Keys.detectSourceRules)
                .flatMap { try? JSONDecoder().decode(SourceRules.self, from: $0) } ?? SourceRules()
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.detectSourceRules)
            NotificationCenter.default.post(name: sourcesChanged, object: nil)
        }
    }

    /// Apps added by hand in Settings > Sources.
    static var customApps: [CustomApp] {
        get {
            defaults.data(forKey: Keys.detectCustomApps)
                .flatMap { try? JSONDecoder().decode([CustomApp].self, from: $0) } ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.detectCustomApps) }
    }

    /// Websites added by hand in Settings > Sources.
    static var customWebsites: [CustomWebsite] {
        get {
            defaults.data(forKey: Keys.detectCustomWebsites)
                .flatMap { try? JSONDecoder().decode([CustomWebsite].self, from: $0) } ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.detectCustomWebsites) }
    }

    /// Sources removed from the Settings list (their rule is Never).
    static var removedSources: [String] {
        get { defaults.stringArray(forKey: Keys.detectRemovedSources) ?? [] }
        set { defaults.set(newValue, forKey: Keys.detectRemovedSources) }
    }

    /// Every call source detected so far, for the Settings list.
    static var seenSources: [String] { defaults.stringArray(forKey: Keys.detectSeenSources) ?? [] }

    static func noteSeen(_ source: String) {
        let seen = seenSources
        guard !seen.contains(where: { $0.caseInsensitiveCompare(source) == .orderedSame }) else { return }
        defaults.set(seen + [source], forKey: Keys.detectSeenSources)
        NotificationCenter.default.post(name: sourcesChanged, object: nil)
    }

    static var autoCleanupEnabled: Bool { defaults.bool(forKey: Keys.autoCleanupEnabled) }
    static var autoCleanupDays: Int { max(1, defaults.integer(forKey: Keys.autoCleanupDays)) }

    /// The popover's sections from their saved form: sections added since it was saved go
    /// to the end, ones that no longer exist are dropped. Nothing saved is the standard layout.
    /// The live transcript is left out where live transcription can't run.
    static func popoverItems(from data: Data?) -> [PopoverItem] {
        let known = PopoverLayout.defaults.filter { $0.section != .live || LiveTranscription.isSupported }
        return PopoverLayout.settled(Reorder.normalized(PopoverLayout.decode(data), known: known, by: \.section))
    }

    /// What the popover shows and in which order.
    static var popoverItems: [PopoverItem] {
        get { popoverItems(from: defaults.data(forKey: Keys.popoverSections)) }
        set { defaults.set(PopoverLayout.encode(newValue), forKey: Keys.popoverSections) }
    }

    /// How many calls the popover lists under Recent.
    static var popoverRecentCount: Int { PopoverLayout.recentCount(defaults.integer(forKey: Keys.popoverRecentCount)) }

    /// Live transcription while recording; always off where no engine can run.
    static var liveEnabled: Bool { LiveTranscription.isSupported && defaults.bool(forKey: Keys.liveEnabled) }

    /// The chosen live engine, or the first one this Mac can run.
    static var liveEngine: LiveEngineKind? {
        let saved = LiveEngineKind(rawValue: defaults.string(forKey: Keys.liveEngine) ?? "")
        return saved.flatMap { $0.isAvailable ? $0 : nil } ?? LiveEngineKind.available.first
    }

    static var liveAfterCall: LiveAfterCall {
        LiveAfterCall(rawValue: defaults.string(forKey: Keys.liveAfterCall) ?? "") ?? .preview
    }

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
    private static let service = "com.gabrielepartiti.kaiku"
    /// Service name used before the app was renamed.
    static let legacyService = "com.gabrielepartiti.mcrofone"

    /// When set, used instead of the real Keychain (snapshot rendering).
    static var mock: [String: String]?

    /// Keychain failures other than "not found", by account, shown instead of "missing key".
    private(set) static var errors: [String: String] = [:]

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

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
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess || status == errSecItemNotFound { errors[account] = nil }
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecSuccess && status != errSecItemNotFound {
                // e.g. a locked keychain: not the same as a key never entered.
                errors[account] = "Couldn't read \(account) from the Keychain: \(describe(status))"
                Log.app.error("Keychain read failed for \(account, privacy: .public): \(describe(status), privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value` (an empty one deletes the item). Updates in place, so a failure never
    /// loses the key saved before. Returns false when the Keychain refused.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        if mock != nil { mock?[account] = value; return true }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(base as CFDictionary)
            if status == errSecItemNotFound { status = errSecSuccess }
        } else {
            let data = Data(value.utf8)
            status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = base
                add[kSecValueData as String] = data
                status = SecItemAdd(add as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else {
            errors[account] = "Couldn't save \(account) in the Keychain: \(describe(status))"
            Log.app.error("Keychain write failed for \(account, privacy: .public): \(describe(status), privacy: .public)")
            return false
        }
        errors[account] = nil
        return true
    }

    /// Copies every generic password of `from` that `service` does not have yet, keeping
    /// the originals. Returns the number of items copied.
    static func copyItems(from legacy: String) -> Int {
        let list: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacy,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(list as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return 0 }
        var copied = 0
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) where get(account) == nil {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacy,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { continue }
            set(value, for: account)
            copied += 1
        }
        return copied
    }

    static func apiKey(for p: ProviderKind) -> String? {
        guard let v = get(p.rawValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}
