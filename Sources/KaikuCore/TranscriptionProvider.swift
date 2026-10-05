import Foundation

/// A speech-to-text backend.
public protocol TranscriptionProvider {
    /// Human readable name, e.g. "OpenAI (gpt-4o-transcribe)".
    var name: String { get }
    /// Whether `diarize: true` produces per-speaker labels.
    var supportsDiarization: Bool { get }
    /// - Parameter language: ISO code, or nil for auto-detection.
    func transcribe(fileURL: URL, language: String?, diarize: Bool) async throws -> TranscriptionResult
}

public struct ProviderError: LocalizedError {
    public let message: String
    /// The HTTP status, when the error is an HTTP response.
    public var httpStatus: Int?
    public init(message: String, httpStatus: Int? = nil) {
        self.message = message
        self.httpStatus = httpStatus
    }
    public var errorDescription: String? { message }
}

/// multipart/form-data body builder.
public struct MultipartForm {
    public let boundary = "kaiku-" + UUID().uuidString
    public private(set) var body = Data()

    public init() {}

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    public mutating func file(_ name: String, url: URL, mime: String) throws {
        let data = try Data(contentsOf: url)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    public mutating func file(_ name: String, data: Data, filename: String, mime: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    public func finalized() -> Data {
        var d = body
        d.append("--\(boundary)--\r\n")
        return d
    }
}

private extension Data {
    public mutating func append(_ s: String) { append(Data(s.utf8)) }
}

public enum HTTP {
    public static func postMultipart(_ url: URL, form: MultipartForm, headers: [String: String], timeout: TimeInterval = 1800) async throws -> Data {
        try await post(url, body: form.finalized(), contentType: form.contentType, headers: headers, timeout: timeout)
    }

    /// Retries transient failures as decided by `UploadRetry`.
    public static func post(_ url: URL, body: Data, contentType: String, headers: [String: String], timeout: TimeInterval = 1800) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        var attempt = 0
        while true {
            let failure: UploadRetry.Failure
            let error: Error
            do {
                let (data, response) = try await URLSession.shared.upload(for: req, from: body)
                guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "No HTTP response") }
                if (200..<300).contains(http.statusCode) { return data }
                let text = String(data: data.prefix(600), encoding: .utf8) ?? ""
                failure = .http(status: http.statusCode, body: text, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                error = ProviderError(message: "HTTP \(http.statusCode) from \(url.host ?? ""): \(text)")
            } catch let e as URLError {
                failure = .network(code: e.errorCode)
                error = e
            }
            attempt += 1
            guard let wait = UploadRetry.delay(after: failure, attempt: attempt) else { throw error }
            Log.transcription.error("Upload attempt \(attempt) to \(url.host ?? "", privacy: .public) failed, retrying in \(Int(wait)) s: \(error.localizedDescription, privacy: .public)")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    public static func postJSON(_ url: URL, body: Data, headers: [String: String], timeout: TimeInterval = 300) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data.prefix(600), encoding: .utf8) ?? ""
            throw ProviderError(message: "HTTP \(http.statusCode) from \(url.host ?? ""): \(text)")
        }
        return data
    }
}

/// Results of the chunks of one track already transcribed, saved next to the track's
/// partial result: when a later chunk fails, trying again doesn't pay for them twice.
/// Set for the duration of a track with `ChunkCache.$current.withValue`.
public final class ChunkCache: @unchecked Sendable {
    @TaskLocal public static var current: ChunkCache?

    private struct Entry: Codable {
        var segments: [Segment]
        var detectedLanguage: String?
    }

    private struct Stored: Codable {
        var key: String
        var chunks: [String: Entry]
    }

    public let url: URL
    private let key: String
    private let lock = NSLock()
    private var chunks: [String: Entry]

    /// - Parameter key: everything that must match for a saved chunk to be reused.
    public init(url: URL, key: TrackCache.Key) {
        self.url = url
        self.key = (try? JSONEncoder().encode(key)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        chunks = stored?.key == self.key ? stored?.chunks ?? [:] : [:]
    }

    private static func id(_ index: Int, offset: Double) -> String { "\(index)@\(Int((offset * 1000).rounded()))" }

    public func result(index: Int, offset: Double) -> TranscriptionResult? {
        lock.lock()
        defer { lock.unlock() }
        return chunks[Self.id(index, offset: offset)].map { TranscriptionResult(segments: $0.segments, detectedLanguage: $0.detectedLanguage) }
    }

    public func save(_ result: TranscriptionResult, index: Int, offset: Double) {
        lock.lock()
        chunks[Self.id(index, offset: offset)] = Entry(segments: result.segments, detectedLanguage: result.detectedLanguage)
        let stored = Stored(key: key, chunks: chunks)
        lock.unlock()
        try? JSONEncoder().encode(stored).write(to: url, options: .atomic)
    }
}
