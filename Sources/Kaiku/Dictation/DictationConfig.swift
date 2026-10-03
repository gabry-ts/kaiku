import Foundation
import KaikuCore

extension Keys {
    static let dictationEnabled = "dictation.enabled"
    static let dictationActivation = "dictation.activation"
    static let dictationProvider = "dictation.provider"
    static let dictationLanguage = "dictation.language"
    /// whisper.cpp model file for dictation; empty uses the light live model.
    static let dictationWhisperModel = "dictation.whisperModel"
    /// Keeps whisper-server loaded while dictation is on, for faster results.
    static let dictationKeepWarm = "dictation.keepWarm"
    static let dictationPolish = "dictation.polish"
    /// Provider of the polish step; unset uses the summary provider.
    static let dictationPolishProvider = "dictation.polishProvider"
    static let dictationPolishPrompt = "dictation.polishPrompt"
    static let dictationModes = "dictation.modes"
    static let dictationActiveMode = "dictation.activeMode"
    static func dictationModel(_ p: ProviderKind) -> String { "dictation.model.\(p.rawValue)" }
    static func dictationPolishModel(_ p: SummaryProviderKind) -> String { "dictation.polishModel.\(p.rawValue)" }
}

extension ProviderKind {
    /// Fast enough for a few seconds of speech: Alibaba's file transcription is a queued job.
    static var dictation: [ProviderKind] { available.filter { $0 != .alibaba } }
}

/// The dictation settings. Off until switched on in Settings: nothing is registered,
/// started or asked for before that.
enum DictationConfig {
    static func registerDefaults() {
        var values: [String: Any] = [
            Keys.dictationEnabled: false,
            Keys.dictationActivation: DictationActivation.hold.rawValue,
            Keys.dictationProvider: defaultProvider.rawValue,
            Keys.dictationLanguage: "",
            Keys.dictationWhisperModel: "",
            Keys.dictationKeepWarm: false,
            Keys.dictationPolish: false,
            Keys.dictationPolishPrompt: DictationPrompt.defaultPrompt,
            Keys.dictationActiveMode: DictationModes.defaults[0].id,
        ]
        for p in ProviderKind.allCases { values[Keys.dictationModel(p)] = p.defaultModel }
        for p in SummaryProviderKind.allCases { values[Keys.dictationPolishModel(p)] = p.defaultModel }
        AppSettings.defaults.register(defaults: values)
    }

    private static var defaults: UserDefaults { AppSettings.defaults }

    /// The system recognizer where it exists: private, free and already fast.
    static var defaultProvider: ProviderKind { ProviderKind.apple.isAvailable ? .apple : .whisperCpp }

    static var enabled: Bool { defaults.bool(forKey: Keys.dictationEnabled) }

    static var activation: DictationActivation {
        DictationActivation(rawValue: defaults.string(forKey: Keys.dictationActivation) ?? "") ?? .hold
    }

    static var provider: ProviderKind {
        let saved = ProviderKind(rawValue: defaults.string(forKey: Keys.dictationProvider) ?? "")
        return saved.flatMap { ProviderKind.dictation.contains($0) ? $0 : nil } ?? defaultProvider
    }

    static func model(for p: ProviderKind) -> String {
        let v = (defaults.string(forKey: Keys.dictationModel(p)) ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? p.defaultModel : v
    }

    /// "auto" or an ISO code; empty in Settings follows the app's language.
    static var language: String {
        let v = (defaults.string(forKey: Keys.dictationLanguage) ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? AppSettings.language : AppSettings.normalizedLanguage(v)
    }

    /// The chosen model file, else the light live one.
    static var whisperModel: String {
        let chosen = ((defaults.string(forKey: Keys.dictationWhisperModel) ?? "") as NSString).expandingTildeInPath
        if !chosen.isEmpty, FileManager.default.fileExists(atPath: chosen) { return chosen }
        return AppSettings.liveWhisperModel
    }

    static var keepWarm: Bool { defaults.bool(forKey: Keys.dictationKeepWarm) }

    static var polish: Bool { defaults.bool(forKey: Keys.dictationPolish) }

    static var polishProvider: SummaryProviderKind {
        SummaryProviderKind(rawValue: defaults.string(forKey: Keys.dictationPolishProvider) ?? "") ?? AppSettings.summaryProvider
    }

    static func polishModel(for p: SummaryProviderKind) -> String {
        let v = (defaults.string(forKey: Keys.dictationPolishModel(p)) ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? p.defaultModel : v
    }

    static var polishPrompt: String { defaults.string(forKey: Keys.dictationPolishPrompt) ?? DictationPrompt.defaultPrompt }

    static var modes: [DictationMode] {
        get { DictationModes.decode(defaults.data(forKey: Keys.dictationModes)) }
        set { defaults.set(DictationModes.encode(newValue), forKey: Keys.dictationModes) }
    }

    static var activeMode: DictationMode? {
        DictationModes.active(id: defaults.string(forKey: Keys.dictationActiveMode), in: modes)
    }

    static func setActiveMode(_ id: String) { defaults.set(id, forKey: Keys.dictationActiveMode) }

    /// Where the latest dictations are kept.
    static var history: DictationHistory {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kaiku/dictation-history.json")
        return DictationHistory(url: url)
    }
}
