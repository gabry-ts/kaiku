import Foundation
import McRofoneCore

/// Local transcription with whisper.cpp's `whisper-cli`.
struct WhisperCppProvider: TranscriptionProvider {
    let binary: String
    let model: String

    var name: String { "whisper.cpp (\((model as NSString).lastPathComponent))" }
    var supportsDiarization: Bool { false }

    func transcribe(fileURL: URL, language: String?, diarize: Bool) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: model) else {
            throw ProviderError(message: "whisper.cpp model not found at \(model). Download one (see README) and set its path in Settings.")
        }
        let dir = try AudioTools.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("input.wav")
        try await AudioTools.toWhisperWav(fileURL, output: wav)

        let outBase = dir.appendingPathComponent("out")
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
        try await Shell.run(binary, [
            "-m", model, "-f", wav.path,
            "-l", language ?? "auto",
            "-t", String(threads),
            "-oj", "-of", outBase.path, "-np",
        ])
        let data = try Data(contentsOf: outBase.appendingPathExtension("json"))
        return try ResponseParsers.whisperCpp(data)
    }
}
