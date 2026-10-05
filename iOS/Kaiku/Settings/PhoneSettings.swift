import Foundation
import KaikuCore

/// UserDefaults keys; views bind to them with @AppStorage. Names match the Mac app where both have the setting.
enum PhoneKeys {
    static let transcriber = "provider"
    static let language = "language"
    static let meLabel = "meLabel"
    static let othersLabel = "othersLabel"
    static let alibabaRegion = "alibabaRegion"
    /// File name of the whisper model in use.
    static let whisperModel = "whisperModel"
    static let compatibleURL = "compatibleURL"
    static let compatibleModel = "compatibleModel"
    static func model(_ p: ProviderKind) -> String { "model.\(p.rawValue)" }
}

/// Settings read outside of views.
enum PhoneSettings {
    static var defaults: UserDefaults { .standard }

    /// The library lives in Documents/Kaiku, in the same folder format as the Mac app.
    static var baseFolder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kaiku", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "auto" or an ISO language code.
    static var language: String {
        let v = (defaults.string(forKey: PhoneKeys.language) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return v.isEmpty ? "auto" : v
    }

    static var meLabel: String { nonEmpty(defaults.string(forKey: PhoneKeys.meLabel), "Me") }
    static var othersLabel: String { nonEmpty(defaults.string(forKey: PhoneKeys.othersLabel), "Others") }

    static var transcriber: TranscriberChoice {
        TranscriberChoice(rawValue: defaults.string(forKey: PhoneKeys.transcriber) ?? "") ?? .apple
    }

    static func model(for p: ProviderKind) -> String {
        nonEmpty(defaults.string(forKey: PhoneKeys.model(p)), p.defaultModel)
    }

    /// Address of the OpenAI-compatible transcription server, as typed.
    static var compatibleURL: String { defaults.string(forKey: PhoneKeys.compatibleURL) ?? "" }
    static var compatibleModel: String {
        (defaults.string(forKey: PhoneKeys.compatibleModel) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var alibabaRegion: AlibabaRegion {
        AlibabaRegion(rawValue: defaults.string(forKey: PhoneKeys.alibabaRegion) ?? "") ?? .singapore
    }

    private static func nonEmpty(_ value: String?, _ fallback: String) -> String {
        let t = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }
}

extension ProviderKind {
    var displayName: String {
        switch self {
        case .whisperCpp: return "Whisper (on this iPhone)"
        case .apple: return "Apple (on this iPhone)"
        case .elevenLabs: return "ElevenLabs Scribe"
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .alibaba: return "Alibaba Cloud"
        }
    }

    /// Suggested model ids for the model field.
    var modelPresets: [String] {
        switch self {
        case .whisperCpp, .apple: return []
        case .elevenLabs: return ["scribe_v2", "scribe_v1"]
        case .openAI: return ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe-diarize", "whisper-1"]
        case .groq: return ["whisper-large-v3-turbo", "whisper-large-v3"]
        case .alibaba: return ["qwen3-asr-flash-filetrans", "qwen3-asr-flash", "fun-asr", "paraformer-v2"]
        }
    }

    /// The key of the service in the Keychain, trimmed; nil when there is none.
    var apiKey: String? {
        guard let v = Keychain.get(rawValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}
