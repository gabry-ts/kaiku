import Foundation
import KaikuCore

/// ElevenLabs Scribe: POST https://api.elevenlabs.io/v1/speech-to-text
struct ElevenLabsProvider: TranscriptionProvider {
    let apiKey: String
    let model: String

    var name: String { "ElevenLabs (\(model))" }
    var supportsDiarization: Bool { true }

    func transcribe(fileURL: URL, language: String?, diarize: Bool) async throws -> TranscriptionResult {
        let dir = try AudioTools.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.m4a")
        try await AudioTools.compress(fileURL, output: audio)

        var form = MultipartForm()
        form.field("model_id", model)
        form.field("diarize", diarize ? "true" : "false")
        form.field("timestamps_granularity", "word")
        form.field("tag_audio_events", "false")
        if let language { form.field("language_code", language) }
        try form.file("file", url: audio, mime: "audio/mp4")

        let data = try await HTTP.postMultipart(
            URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
            form: form, headers: ["xi-api-key": apiKey])
        return try ResponseParsers.elevenLabs(data, diarized: diarize)
    }
}
