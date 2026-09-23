import Foundation
import McRofoneCore

/// OpenAI `/audio/transcriptions` and compatible APIs (Groq).
///
/// Response format is picked from the model name:
/// - `*diarize*` models: `diarized_json` (speaker labels + timestamps)
/// - `whisper*` models: `verbose_json` (segment timestamps + language)
/// - anything else (e.g. `gpt-4o-transcribe`): `json` (text only, no timestamps),
///   so audio is sent in short chunks to keep the transcript roughly time-aligned.
struct OpenAICompatibleProvider: TranscriptionProvider {
    let label: String
    let baseURL: URL
    let apiKey: String
    let model: String

    var name: String { "\(label) (\(model))" }

    private var isDiarizeModel: Bool { model.lowercased().contains("diarize") }
    private var isWhisperModel: Bool { model.lowercased().hasPrefix("whisper") }
    var supportsDiarization: Bool { isDiarizeModel }

    private var responseFormat: String {
        isDiarizeModel ? "diarized_json" : (isWhisperModel ? "verbose_json" : "json")
    }

    /// Chunk length in seconds. Upload limit is 25 MB; at 32 kbps mono MP3 10 min is ~2.4 MB.
    private var chunkSeconds: Int { (isDiarizeModel || isWhisperModel) ? 600 : 60 }

    func transcribe(fileURL: URL, language: String?, diarize: Bool) async throws -> TranscriptionResult {
        let dir = try AudioTools.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunks = try await AudioTools.chunks(fileURL, seconds: chunkSeconds, dir: dir)
        var segments: [Segment] = []
        var detected: String?
        for (index, chunk) in chunks.enumerated() {
            var form = MultipartForm()
            form.field("model", model)
            form.field("response_format", responseFormat)
            if isDiarizeModel { form.field("chunking_strategy", "auto") }
            if let language { form.field("language", language) }
            try form.file("file", url: chunk.url, mime: "audio/mpeg")

            let data = try await HTTP.postMultipart(
                baseURL.appendingPathComponent("audio/transcriptions"),
                form: form, headers: ["Authorization": "Bearer \(apiKey)"])
            var result = try ResponseParsers.openAI(data, offset: chunk.offset, chunkDuration: chunk.duration)
            if isDiarizeModel {
                // Speaker ids are only consistent within one request.
                result.segments = result.segments.map { s in
                    var c = s
                    if let sp = s.speaker { c.speaker = "\(index)-\(sp)" }
                    return c
                }
            }
            if !diarize { result.segments = result.segments.map { var c = $0; c.speaker = nil; return c } }
            segments += result.segments
            detected = detected ?? result.detectedLanguage
        }
        return TranscriptionResult(segments: segments, detectedLanguage: detected)
    }
}
