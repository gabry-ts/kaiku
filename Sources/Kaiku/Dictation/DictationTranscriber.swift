import Foundation
import KaikuCore

/// Turns a recorded dictation into text with the chosen provider: the audio is saved as a
/// short WAV and handed to the same providers that transcribe calls.
enum DictationTranscriber {
    static func transcribe(_ samples: [Int16], provider kind: ProviderKind, language: String) async throws -> String {
        let wav = ChunkAudio.wav(samples, sampleRate: DictationRecorder.sampleRate)
        let code: String? = language == "auto" ? nil : language

        if kind == .whisperCpp, DictationConfig.keepWarm {
            let seconds = Double(samples.count) / Double(DictationRecorder.sampleRate)
            let server = try await DictationWhisper.shared.server()
            let text = try await server.transcribe(wav: wav, language: language,
                                                   audioContext: WhisperServer.audioContext(seconds: seconds))
            return DictationText.join([OverlapText.spoken(text)])
        }

        let dir = try AudioTools.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dictation.wav")
        try wav.write(to: file)
        let result = try await provider(kind).transcribe(fileURL: file, language: code, diarize: false)
        let pieces = result.segments.map(\.text)
        return DictationText.join(kind == .whisperCpp ? pieces.map(OverlapText.spoken) : pieces)
    }

    /// The provider with the dictation model, not the one chosen for calls.
    private static func provider(_ kind: ProviderKind) throws -> TranscriptionProvider {
        let model = DictationConfig.model(for: kind)
        func key() throws -> String {
            guard let k = Keychain.apiKey(for: kind) else {
                throw ProviderError(message: "No \(kind.displayName) key yet. Add it in Settings > Accounts.")
            }
            return k
        }
        switch kind {
        case .whisperCpp:
            return WhisperCppProvider(binary: AppSettings.whisperPath, model: DictationConfig.whisperModel)
        case .openAI:
            return OpenAICompatibleProvider(label: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!,
                                            apiKey: try key(), model: model)
        case .groq:
            return OpenAICompatibleProvider(label: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!,
                                            apiKey: try key(), model: model)
        case .elevenLabs:
            return ElevenLabsProvider(apiKey: try key(), model: model)
        case .apple, .alibaba:
            return try ProviderFactory.make(kind)
        }
    }
}

/// A whisper-server kept loaded while dictation uses whisper.cpp with Keep Warm on, so a
/// dictation doesn't wait for the model to load.
@MainActor
final class DictationWhisper {
    static let shared = DictationWhisper()

    private var running: (server: WhisperServer, model: String, language: String)?
    private var starting: Task<WhisperServer, Error>?

    /// The running server for the current model and language, started when needed.
    func server() async throws -> WhisperServer {
        let model = DictationConfig.whisperModel
        let language = DictationConfig.language
        if let running, running.model == model, running.language == language { return running.server }
        if let starting { return try await starting.value }
        stop()
        guard let binary = WhisperServer.detect() else { throw ProviderError(message: WhisperServer.missingHelp) }
        guard FileManager.default.fileExists(atPath: model) else {
            throw ProviderError(message: "No whisper.cpp model yet. Download one in Settings > Transcription.")
        }
        let task = Task { try await WhisperServer.start(binary: binary, model: model, language: language) }
        starting = task
        defer { starting = nil }
        let server = try await task.value
        running = (server, model, language)
        Log.transcription.info("Dictation whisper-server ready with \((model as NSString).lastPathComponent, privacy: .public)")
        return server
    }

    /// Starts or stops the server to match the settings.
    func apply() {
        let wanted = DictationConfig.enabled && DictationConfig.provider == .whisperCpp && DictationConfig.keepWarm
        guard wanted else { stop(); return }
        Task { _ = try? await server() }
    }

    func stop() {
        starting?.cancel()
        starting = nil
        running?.server.stop()
        running = nil
    }
}
