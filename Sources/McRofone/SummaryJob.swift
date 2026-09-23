import Foundation
import McRofoneCore

/// Writes summary.md for a call with the user's own API key. Only runs when
/// enabled in Settings or when asked from the Library.
enum SummaryJob {
    static func run(folder: RecordingFolder, provider kind: SummaryProviderKind = AppSettings.summaryProvider) async throws {
        guard let transcript = try? String(contentsOf: folder.transcriptURL, encoding: .utf8) else {
            throw ProviderError(message: "This call has no transcript yet.")
        }
        guard let key = kind.apiKey else {
            throw ProviderError(message: "Missing API key for \(kind.displayName). Add it in Settings > Transcription > Summary.")
        }
        let meta = folder.loadMeta()
        let model = AppSettings.summaryModel(for: kind)
        let prompt = SummaryAPI.renderPrompt(template: AppSettings.summaryPrompt, title: meta?.title ?? "", transcript: transcript)

        let text: String
        switch kind {
        case .anthropic:
            let data = try await HTTP.postJSON(
                URL(string: "https://api.anthropic.com/v1/messages")!,
                body: try SummaryAPI.anthropicBody(model: model, prompt: prompt),
                headers: ["x-api-key": key, "anthropic-version": "2023-06-01"])
            text = try SummaryAPI.parseAnthropic(data)
        case .openAI, .groq:
            let base = kind == .openAI ? "https://api.openai.com/v1" : "https://api.groq.com/openai/v1"
            let data = try await HTTP.postJSON(
                URL(string: base + "/chat/completions")!,
                body: try SummaryAPI.chatCompletionsBody(model: model, prompt: prompt),
                headers: ["Authorization": "Bearer \(key)"])
            text = try SummaryAPI.parseChatCompletions(data)
        }
        try (text + "\n").write(to: folder.summaryURL, atomically: true, encoding: .utf8)
        folder.updateMeta { $0.summaryModel = "\(kind.displayName) (\(model))" }
    }
}

extension HTTP {
    static func postJSON(_ url: URL, body: Data, headers: [String: String], timeout: TimeInterval = 300) async throws -> Data {
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
