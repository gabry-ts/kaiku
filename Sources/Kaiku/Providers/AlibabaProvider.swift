import Foundation
import KaikuCore

/// Alibaba Cloud Model Studio (DashScope). The flow is picked from the model name:
/// - `qwen3-asr-flash*`: OpenAI-compatible `chat/completions`, text only and at most
///   5 minutes per request, so audio is sent in parts.
/// - every other model (`*-filetrans`, `fun-asr*`, `paraformer-*`): the recording is uploaded
///   to DashScope's temporary storage and transcribed by an asynchronous task, with sentence
///   timestamps.
struct AlibabaProvider: TranscriptionProvider {
    let region: AlibabaRegion
    let apiKey: String
    let model: String

    var name: String { "Alibaba Cloud (\(model))" }

    /// Models that take short base64 parts instead of an uploaded file.
    static func isChunked(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("qwen3-asr-flash") && !m.contains("filetrans")
    }

    /// Qwen3 file transcription takes one `file_url` and a `language`; the other file models
    /// take `file_urls` and `language_hints`, and can tell speakers apart.
    private var isQwen3File: Bool { model.lowercased().hasPrefix("qwen3-asr") }

    var supportsDiarization: Bool { !Self.isChunked(model) && !isQwen3File }

    /// Stays under the 5-minute limit of a single request.
    private static let chunkSeconds = 280

    private var api: URL { URL(string: "https://\(region.host)/api/v1")! }
    private var auth: [String: String] { ["Authorization": "Bearer \(apiKey)"] }

    func transcribe(fileURL: URL, language: String?, diarize: Bool) async throws -> TranscriptionResult {
        let dir = try AudioTools.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        if Self.isChunked(model) {
            return try await transcribeChunks(fileURL, language: language, dir: dir)
        }
        let audio = dir.appendingPathComponent(UUID().uuidString + ".m4a")
        try await AudioTools.compress(fileURL, output: audio)
        let diarized = diarize && supportsDiarization
        let stored = try await upload(audio)
        let resultURL = try await runTask(fileURL: stored, language: language, diarize: diarized)
        return try ResponseParsers.alibabaFile(try await get(resultURL, headers: [:]), diarized: diarized)
    }

    // MARK: Short requests

    private func transcribeChunks(_ fileURL: URL, language: String?, dir: URL) async throws -> TranscriptionResult {
        let chunks = try await AudioTools.chunks(fileURL, seconds: Self.chunkSeconds, dir: dir)
        let url = URL(string: "https://\(region.host)/compatible-mode/v1/chat/completions")!
        var segments: [Segment] = []
        var detected: String?
        for chunk in chunks {
            let audio = "data:audio/mp4;base64," + (try Data(contentsOf: chunk.url)).base64EncodedString()
            var body: [String: Any] = [
                "model": model,
                "messages": [["role": "user", "content": [["type": "input_audio", "input_audio": ["data": audio]]]]],
                "stream": false,
            ]
            if let language { body["asr_options"] = ["language": language] }
            let data = try await HTTP.post(url, body: try JSONSerialization.data(withJSONObject: body),
                                           contentType: "application/json", headers: auth)
            let result = try ResponseParsers.alibabaChat(data, offset: chunk.offset, chunkDuration: chunk.duration)
            segments += result.segments
            detected = detected ?? result.detectedLanguage
        }
        return TranscriptionResult(segments: segments, detectedLanguage: detected)
    }

    // MARK: File transcription

    private struct Policy: Decodable {
        struct Body: Decodable {
            let policy: String
            let signature: String
            let upload_dir: String
            let upload_host: String
            let oss_access_key_id: String
            let x_oss_object_acl: String
            let x_oss_forbid_overwrite: String
        }
        let data: Body
    }

    /// Uploads to DashScope's temporary storage (deleted after 48 hours) and returns the
    /// `oss://` URL, usable only with this model and this API key.
    private func upload(_ file: URL) async throws -> String {
        var components = URLComponents(url: api.appendingPathComponent("uploads"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "getPolicy"), URLQueryItem(name: "model", value: model)]
        let policy = try decode(Policy.self, try await get(components.url!, headers: auth)).data
        guard let host = URL(string: policy.upload_host) else {
            throw ProviderError(message: "Alibaba Cloud returned an invalid upload address.")
        }
        let key = "\(policy.upload_dir)/\(file.lastPathComponent)"
        var form = MultipartForm()
        form.field("OSSAccessKeyId", policy.oss_access_key_id)
        form.field("Signature", policy.signature)
        form.field("policy", policy.policy)
        form.field("x-oss-object-acl", policy.x_oss_object_acl)
        form.field("x-oss-forbid-overwrite", policy.x_oss_forbid_overwrite)
        form.field("key", key)
        form.field("success_action_status", "200")
        try form.file("file", url: file, mime: "audio/mp4")
        _ = try await HTTP.postMultipart(host, form: form, headers: [:])
        return "oss://\(key)"
    }

    private struct TaskResponse: Decodable {
        struct Output: Decodable {
            struct Result: Decodable {
                let transcription_url: String?
                let subtask_status: String?
                let message: String?
            }
            let task_id: String
            let task_status: String
            let result: Result?
            let results: [Result]?
            let code: String?
            let message: String?
        }
        let output: Output
    }

    /// Submits the task, waits for it and returns the address of the result file.
    private func runTask(fileURL: String, language: String?, diarize: Bool) async throws -> URL {
        var input: [String: Any] = [:]
        var parameters: [String: Any] = [:]
        if isQwen3File {
            input["file_url"] = fileURL
            if let language { parameters["language"] = language }
        } else {
            input["file_urls"] = [fileURL]
            if let language { parameters["language_hints"] = [language] }
            parameters["diarization_enabled"] = diarize
        }
        let body = try JSONSerialization.data(withJSONObject: ["model": model, "input": input, "parameters": parameters])
        let headers = auth.merging(["X-DashScope-Async": "enable", "X-DashScope-OssResourceResolve": "enable"]) { $1 }
        let submitted = try decode(TaskResponse.self, try await HTTP.post(
            api.appendingPathComponent("services/audio/asr/transcription"),
            body: body, contentType: "application/json", headers: headers))

        let taskURL = api.appendingPathComponent("tasks/\(submitted.output.task_id)")
        while true {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let output = try decode(TaskResponse.self, try await get(taskURL, headers: auth)).output
            switch output.task_status {
            case "SUCCEEDED":
                let result = output.result ?? output.results?.first
                // Result files may be linked over plain http, which App Transport Security blocks.
                guard let link = result?.transcription_url?.replacingOccurrences(of: "http://", with: "https://"),
                      let url = URL(string: link) else {
                    throw ProviderError(message: "Alibaba Cloud returned no transcript: \(result?.message ?? result?.subtask_status ?? "no details")")
                }
                return url
            case "FAILED", "CANCELED", "UNKNOWN":
                throw ProviderError(message: "Alibaba Cloud task \(output.task_status.lowercased()): \(output.message ?? output.code ?? "no details")")
            default:
                continue
            }
        }
    }

    // MARK: Helpers

    private func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 60)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data.prefix(600), encoding: .utf8) ?? ""
            throw ProviderError(message: "HTTP \(status) from \(url.host ?? ""): \(text)")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ParseError.invalid("Alibaba Cloud JSON: \(error)") }
    }
}
