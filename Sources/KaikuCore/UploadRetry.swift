import Foundation

/// When a failed upload to a transcription provider is worth trying again.
public enum UploadRetry {
    public static let maxRetries = 3
    /// Longer waits asked by the provider are not worth it: give up instead.
    public static let maxWait: Double = 60

    public enum Failure: Equatable, Sendable {
        /// URLError code.
        case network(code: Int)
        case http(status: Int, body: String, retryAfter: String?)
    }

    /// Seconds to wait before retry number `attempt` (1-based), or nil to give up.
    /// Retries network errors, 429 and 5xx with a 1 s / 2 s / 4 s backoff, never a timeout
    /// (each one already took up to 30 min), an exhausted quota or any other 4xx.
    public static func delay(after failure: Failure, attempt: Int) -> Double? {
        guard attempt >= 1, attempt <= maxRetries else { return nil }
        let backoff = Double(1 << (attempt - 1))
        switch failure {
        case .network(let code):
            return code == NSURLErrorTimedOut || code == NSURLErrorCancelled ? nil : backoff
        case .http(let status, let body, let retryAfter):
            guard status == 429 || (500...599).contains(status) else { return nil }
            if status == 429 && body.contains("insufficient_quota") { return nil }
            let wait = max(backoff, retryAfter.flatMap(seconds) ?? 0)
            return wait <= maxWait ? wait : nil
        }
    }

    /// `Retry-After` in seconds; the HTTP-date form is not used by the providers.
    static func seconds(_ header: String) -> Double? {
        Double(header.trimmingCharacters(in: .whitespaces)).map { max(0, $0) }
    }
}
