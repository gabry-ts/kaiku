import Foundation
import KaikuCore

enum ProviderFactory {
    static func make(_ kind: ProviderKind) throws -> TranscriptionProvider {
        let model = AppSettings.model(for: kind)
        func key() throws -> String {
            guard let k = Keychain.apiKey(for: kind) else {
                if let problem = Keychain.errors[kind.rawValue] { throw ProviderError(message: problem) }
                throw ProviderError(message: "Missing API key for \(kind.displayName). Add it in Settings > Accounts.")
            }
            return k
        }
        switch kind {
        case .whisperCpp:
            return WhisperCppProvider(binary: AppSettings.whisperPath, model: AppSettings.whisperModel)
        case .apple:
            guard #available(macOS 26, *) else {
                throw ProviderError(message: "The system speech recognizer needs macOS 26 or later.")
            }
            return AppleSpeechProvider()
        case .elevenLabs:
            return ElevenLabsProvider(apiKey: try key(), model: model)
        case .openAI:
            return OpenAICompatibleProvider(
                label: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: try key(), model: model)
        case .groq:
            return OpenAICompatibleProvider(
                label: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!, apiKey: try key(), model: model)
        case .alibaba:
            return AlibabaProvider(region: AppSettings.alibabaRegion, apiKey: try key(), model: model)
        }
    }
}
