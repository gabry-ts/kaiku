import Foundation
import KaikuCore

struct WebhookResult {
    let statusCode: Int
    let bodyPrefix: String
    var ok: Bool { (200..<300).contains(statusCode) }
}

struct WebhookError: LocalizedError {
    let statusCode: Int?
    let message: String
    var errorDescription: String? {
        statusCode.map { "Webhook failed with HTTP \($0): \(message)" } ?? "Webhook failed: \(message)"
    }
}

/// Sends the configured webhook for a recording, reading everything from its folder.
enum Webhook {
    /// Values available to the default payload and to custom templates.
    struct Payload {
        var title: String
        var date: String
        var durationSeconds: Int
        var language: String
        var provider: String
        var folderPath: String
        var transcriptPath: String
        var transcriptMarkdown: String
        var audioPaths: [String]
        var segments: [Segment]
        var speakerNames: [String: String]
        var bookmarks: [Bookmark] = []
        var summaryMarkdown: String?
        var estimatedCostUSD: Double?
        var tags: [String] = []

        var bookmarksJSON: [[String: Any]] {
            bookmarks.sorted { $0.time < $1.time }.map { ["time": $0.time, "label": $0.label] }
        }

        var segmentsJSON: [[String: Any]] {
            segments.map { ["start": $0.start, "end": $0.end, "speaker": $0.speaker ?? "", "text": $0.text] }
        }

        func defaultBody() throws -> Data {
            let dict: [String: Any] = [
                "title": title,
                "date": date,
                "duration_seconds": durationSeconds,
                "language": language,
                "provider": provider,
                "folder_path": folderPath,
                "transcript_path": transcriptPath,
                "audio_paths": audioPaths,
                "transcript_markdown": transcriptMarkdown,
                "segments": segmentsJSON,
                "speaker_names": speakerNames,
                "bookmarks": bookmarksJSON,
                "summary_markdown": summaryMarkdown ?? NSNull(),
                "estimated_cost_usd": estimatedCostUSD ?? NSNull(),
                "tags": tags,
            ]
            return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }

        func templateValues() -> [String: WebhookTemplate.Value] {
            func json(_ obj: Any) -> String {
                (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            }
            return [
                "title": .string(title),
                "date": .string(date),
                "duration_seconds": .raw(String(durationSeconds)),
                "language": .string(language),
                "provider": .string(provider),
                "folder_path": .string(folderPath),
                "transcript_path": .string(transcriptPath),
                "transcript_markdown": .string(transcriptMarkdown),
                "segments_json": .raw(json(segmentsJSON)),
                "audio_paths_json": .raw(json(audioPaths)),
                "bookmarks_json": .raw(json(bookmarksJSON)),
                "summary_markdown": .string(summaryMarkdown ?? ""),
                "estimated_cost_usd": .raw(estimatedCostUSD.map { String(format: "%.4f", $0) } ?? "null"),
                "tags": .string(tags.joined(separator: ", ")),
                "tags_json": .raw(json(tags)),
            ]
        }

        static func from(folder: RecordingFolder) throws -> Payload {
            guard let meta = folder.loadMeta() else { throw WebhookError(statusCode: nil, message: "meta.json missing") }
            guard let markdown = try? String(contentsOf: folder.transcriptURL, encoding: .utf8) else {
                throw WebhookError(statusCode: nil, message: "No transcript for this recording yet")
            }
            let raw = folder.loadSegments() ?? []
            return Payload(
                title: meta.title,
                date: ISO8601DateFormatter().string(from: meta.date),
                durationSeconds: Int(meta.durationSeconds.rounded()),
                language: meta.language == "auto" ? (meta.detectedLanguage ?? "auto") : meta.language,
                provider: meta.model ?? meta.provider ?? "",
                folderPath: folder.url.path,
                transcriptPath: folder.transcriptURL.path,
                transcriptMarkdown: markdown,
                audioPaths: folder.audioURLs.map(\.path),
                segments: TranscriptWriter.displaySegments(meta: meta, rawSegments: raw),
                speakerNames: meta.speakerNames ?? [:],
                bookmarks: meta.bookmarks ?? [],
                summaryMarkdown: folder.summary,
                estimatedCostUSD: meta.estimatedCostUSD,
                tags: meta.tags ?? [])
        }

        static var sample: Payload {
            Payload(
                title: "Sample call", date: ISO8601DateFormatter().string(from: Date()), durationSeconds: 65,
                language: "it", provider: "sample", folderPath: "/tmp/sample", transcriptPath: "/tmp/sample/transcript.md",
                transcriptMarkdown: "# Sample call\n\n**[00:00:01] Me:** Ciao, \"test\" webhook.\n",
                audioPaths: ["/tmp/sample/mic.m4a"],
                segments: [Segment(start: 1, end: 3, speaker: "Me", text: "Ciao, \"test\" webhook.")],
                speakerNames: [:],
                bookmarks: [Bookmark(time: 2, label: "Sample bookmark")],
                summaryMarkdown: "## Summary\nA sample call.",
                estimatedCostUSD: 0.0065,
                tags: ["Sample"])
        }
    }

    static func send(folder: RecordingFolder) async throws -> WebhookResult {
        try await send(payload: try Payload.from(folder: folder))
    }

    /// Sends with up to 3 retries (1 s, 2 s, 4 s) on network errors, 429 and 5xx.
    static func send(payload: Payload) async throws -> WebhookResult {
        let request = try makeRequest(payload: payload)
        var lastError: Error?
        for attempt in 0...3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 1_000_000_000) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let result = WebhookResult(statusCode: code, bodyPrefix: String(decoding: data.prefix(500), as: UTF8.self))
                if result.ok { return result }
                lastError = WebhookError(statusCode: code, message: result.bodyPrefix)
                Log.app.error("Webhook attempt \(attempt + 1) got HTTP \(code)")
                if !(code == 429 || code >= 500) { break }
            } catch {
                lastError = WebhookError(statusCode: nil, message: error.localizedDescription)
                Log.app.error("Webhook attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw lastError ?? WebhookError(statusCode: nil, message: "unknown error")
    }

    private static func makeRequest(payload: Payload) throws -> URLRequest {
        guard let url = URL(string: AppSettings.webhookURL.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw WebhookError(statusCode: nil, message: "Invalid webhook URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = AppSettings.webhookMethod
        if AppSettings.webhookUsesTemplate {
            let contentType = AppSettings.webhookContentType
            let body = WebhookTemplate.render(
                AppSettings.webhookTemplate, values: payload.templateValues(),
                jsonEscape: contentType.lowercased().contains("json"))
            req.httpBody = Data(body.utf8)
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        } else {
            req.httpBody = try payload.defaultBody()
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for header in AppSettings.webhookHeaders {
            req.setValue(header.value, forHTTPHeaderField: header.name.trimmingCharacters(in: .whitespaces))
        }
        return req
    }
}
