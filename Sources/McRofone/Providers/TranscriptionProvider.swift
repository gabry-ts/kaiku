import Foundation
import McRofoneCore

/// A speech-to-text backend.
protocol TranscriptionProvider {
    /// Human readable name, e.g. "OpenAI (gpt-4o-transcribe)".
    var name: String { get }
    /// Whether `diarize: true` produces per-speaker labels.
    var supportsDiarization: Bool { get }
    /// - Parameter language: ISO code, or nil for auto-detection.
    func transcribe(fileURL: URL, language: String?, diarize: Bool) async throws -> TranscriptionResult
}

struct ProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ProviderFactory {
    static func make(_ kind: ProviderKind) throws -> TranscriptionProvider {
        let model = AppSettings.model(for: kind)
        func key() throws -> String {
            guard let k = Keychain.apiKey(for: kind) else {
                throw ProviderError(message: "Missing API key for \(kind.displayName). Add it in Settings.")
            }
            return k
        }
        switch kind {
        case .whisperCpp:
            return WhisperCppProvider(binary: AppSettings.whisperPath, model: AppSettings.whisperModel)
        case .elevenLabs:
            return ElevenLabsProvider(apiKey: try key(), model: model)
        case .openAI:
            return OpenAICompatibleProvider(
                label: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: try key(), model: model)
        case .groq:
            return OpenAICompatibleProvider(
                label: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!, apiKey: try key(), model: model)
        }
    }
}

/// multipart/form-data body builder.
struct MultipartForm {
    let boundary = "mcrofone-" + UUID().uuidString
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func file(_ name: String, url: URL, mime: String) throws {
        let data = try Data(contentsOf: url)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    func finalized() -> Data {
        var d = body
        d.append("--\(boundary)--\r\n")
        return d
    }
}

private extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}

enum HTTP {
    static func postMultipart(_ url: URL, form: MultipartForm, headers: [String: String], timeout: TimeInterval = 1800) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.upload(for: req, from: form.finalized())
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(600), encoding: .utf8) ?? ""
            throw ProviderError(message: "HTTP \(http.statusCode) from \(url.host ?? ""): \(body)")
        }
        return data
    }
}
