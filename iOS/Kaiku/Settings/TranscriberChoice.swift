import Foundation
import KaikuCore

/// The speech-to-text engine chosen in Settings.
enum TranscriberChoice: Hashable, Identifiable {
    case apple
    case whisper
    case cloud(ProviderKind)
    /// An OpenAI-compatible server at an address the user gives, on the local network or elsewhere.
    case compatible

    static let all: [TranscriberChoice] = [.apple, .whisper] + [ProviderKind.openAI, .groq, .elevenLabs, .alibaba].map { .cloud($0) }
        + [.compatible]

    /// Keychain account of the optional key of the compatible server.
    static let compatibleKeyAccount = "compatible"

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .apple: return ProviderKind.apple.rawValue
        case .whisper: return ProviderKind.whisperCpp.rawValue
        case .cloud(let kind): return kind.rawValue
        case .compatible: return "compatible"
        }
    }

    init?(rawValue: String) {
        if rawValue == "compatible" { self = .compatible; return }
        guard let kind = ProviderKind(rawValue: rawValue) else { return nil }
        switch kind {
        case .apple: self = .apple
        case .whisperCpp: self = .whisper
        case .elevenLabs, .openAI, .groq, .alibaba: self = .cloud(kind)
        }
    }

    var displayName: String {
        switch self {
        case .apple: return ProviderKind.apple.displayName
        case .whisper: return ProviderKind.whisperCpp.displayName
        case .cloud(let kind): return kind.displayName
        case .compatible: return "OpenAI-compatible server"
        }
    }

    /// What a transcription run reads from Settings.
    func config() -> TranscriptionRun.Config {
        var model: String?
        switch self {
        case .apple, .whisper: model = nil
        case .cloud(let kind): model = PhoneSettings.model(for: kind)
        case .compatible: model = PhoneSettings.compatibleModel
        }
        let remote = model != nil
        return TranscriptionRun.Config(
            providerDisplayName: displayName,
            modelID: model,
            // Long silences are cut before uploading, like the Mac app does for cloud providers.
            trim: remote,
            trimOptions: SilenceTrimmer.Options(),
            meLabel: PhoneSettings.meLabel,
            othersLabel: PhoneSettings.othersLabel,
            removeEcho: false,
            priceOverrides: [:])
    }

    func makeProvider() throws -> TranscriptionProvider {
        switch self {
        case .apple:
            return AppleSpeechProvider()
        case .whisper:
            guard let model = WhisperDownloader.activeModel else {
                throw ProviderError(message: "No whisper model is downloaded. Get one in Settings > Transcription > Whisper models.")
            }
            return WhisperLibProvider(modelURL: model.localURL)
        case .compatible:
            guard let base = LocalLLM.customChatBase(PhoneSettings.compatibleURL), let url = URL(string: base) else {
                throw ProviderError(message: "No server address yet. Add it in Settings > Transcription.")
            }
            let model = PhoneSettings.compatibleModel
            guard !model.isEmpty else { throw ProviderError(message: "The server needs a model name. Add it in Settings > Transcription.") }
            let key = (Keychain.get(Self.compatibleKeyAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return OpenAICompatibleProvider(label: "Server", baseURL: url, apiKey: key, model: model)
        case .cloud(let kind):
            func key() throws -> String {
                guard let k = kind.apiKey else {
                    if let problem = Keychain.errors[kind.rawValue] { throw ProviderError(message: problem) }
                    throw ProviderError(message: "Missing API key for \(kind.displayName). Add it in Settings > Accounts.")
                }
                return k
            }
            let model = PhoneSettings.model(for: kind)
            switch kind {
            case .elevenLabs:
                return ElevenLabsProvider(apiKey: try key(), model: model)
            case .openAI:
                return OpenAICompatibleProvider(label: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!,
                                                apiKey: try key(), model: model)
            case .groq:
                return OpenAICompatibleProvider(label: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!,
                                                apiKey: try key(), model: model)
            case .alibaba:
                return AlibabaProvider(region: PhoneSettings.alibabaRegion, apiKey: try key(), model: model)
            case .apple, .whisperCpp:
                throw ProviderError(message: "\(kind.displayName) isn't a cloud service.")
            }
        }
    }
}
