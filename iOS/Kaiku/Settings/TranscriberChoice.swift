import Foundation
import KaikuCore

/// The speech-to-text engine chosen in Settings.
enum TranscriberChoice: Hashable, Identifiable {
    case apple
    case whisper
    case cloud(ProviderKind)

    static let all: [TranscriberChoice] = [.apple, .whisper] + [ProviderKind.openAI, .groq, .elevenLabs, .alibaba].map { .cloud($0) }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .apple: return ProviderKind.apple.rawValue
        case .whisper: return ProviderKind.whisperCpp.rawValue
        case .cloud(let kind): return kind.rawValue
        }
    }

    init?(rawValue: String) {
        guard let kind = ProviderKind(rawValue: rawValue) else { return nil }
        switch kind {
        case .apple: self = .apple
        case .whisperCpp: self = .whisper
        case .elevenLabs, .openAI, .groq, .alibaba: self = .cloud(kind)
        }
    }

    var kind: ProviderKind {
        switch self {
        case .apple: return .apple
        case .whisper: return .whisperCpp
        case .cloud(let kind): return kind
        }
    }

    var displayName: String { kind.displayName }

    /// What a transcription run reads from Settings.
    func config() -> TranscriptionRun.Config {
        TranscriptionRun.Config(
            providerDisplayName: displayName,
            modelID: kind.isCloud ? PhoneSettings.model(for: kind) : nil,
            // Long silences are cut before uploading, like the Mac app does for cloud providers.
            trim: kind.isCloud,
            trimOptions: SilenceTrimmer.Options(),
            meLabel: PhoneSettings.meLabel,
            othersLabel: PhoneSettings.othersLabel,
            removeEcho: false,
            priceOverrides: [:])
    }

    func makeProvider() throws -> TranscriptionProvider {
        func key() throws -> String {
            guard let k = kind.apiKey else {
                if let problem = Keychain.errors[kind.rawValue] { throw ProviderError(message: problem) }
                throw ProviderError(message: "Missing API key for \(kind.displayName). Add it in Settings > Accounts.")
            }
            return k
        }
        let model = PhoneSettings.model(for: kind)
        switch self {
        case .apple:
            return AppleSpeechProvider()
        case .whisper:
            guard let model = WhisperDownloader.activeModel else {
                throw ProviderError(message: "No whisper model is downloaded. Get one in Settings > Transcription > Whisper models.")
            }
            return WhisperLibProvider(modelURL: model.localURL)
        case .cloud(let kind):
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
                return AppleSpeechProvider()
            }
        }
    }
}
