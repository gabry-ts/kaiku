import Foundation
import KaikuCore

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
        let json = outBase.appendingPathExtension("json")
        do {
            try await Shell.run(binary, [
                "-m", model, "-f", wav.path,
                "-l", language ?? "auto",
                "-t", String(threads),
                "-oj", "-of", outBase.path, "-np",
            ])
        } catch {
            // whisper.cpp can abort while releasing the Metal device at exit, after the
            // transcript was written. Accept the output if it is complete and parses.
            guard let data = try? Data(contentsOf: json), let result = try? ResponseParsers.whisperCpp(data) else { throw error }
            Log.transcription.info("whisper-cli exited with an error after writing its output: \(error.localizedDescription, privacy: .public)")
            return result
        }
        return try ResponseParsers.whisperCpp(Data(contentsOf: json))
    }
}
