import Foundation

/// An HTTP chat API reached with the user's own key: Anthropic's, or an OpenAI-style one.
public struct LLMEndpoint: Sendable {
    public enum Style: Sendable {
        case anthropic
        /// `base` is the address before `/chat/completions`.
        case chatCompletions(base: String)
    }

    /// Shown in errors, e.g. "OpenAI".
    public var name: String
    public var style: Style
    /// Empty for local servers, which usually take no key.
    public var apiKey: String
    /// Asks for the whole answer when the API refuses to stream (OpenAI, for unverified organizations).
    public var streamFallback: Bool

    public init(name: String, style: Style, apiKey: String, streamFallback: Bool = false) {
        self.name = name
        self.style = style
        self.apiKey = apiKey
        self.streamFallback = streamFallback
    }

    /// The URL and headers every request to this endpoint takes.
    public var target: (url: URL, headers: [String: String]) {
        switch style {
        case .anthropic:
            return (URL(string: "https://api.anthropic.com/v1/messages")!,
                    ["x-api-key": apiKey, "anthropic-version": "2023-06-01"])
        case .chatCompletions(let base):
            // Local servers usually take no key.
            return (URL(string: base + "/chat/completions")!, apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"])
        }
    }

    /// Sends one prompt and returns the text of the answer.
    public func complete(model: String, prompt: String, maxTokens: Int = 4096, timeout: TimeInterval = 300) async throws -> String {
        let (url, headers) = target
        switch style {
        case .anthropic:
            let data = try await HTTP.postJSON(
                url, body: try SummaryAPI.anthropicBody(model: model, prompt: prompt, maxTokens: maxTokens),
                headers: headers, timeout: timeout)
            return try SummaryAPI.parseAnthropic(data)
        case .chatCompletions:
            let data = try await HTTP.postJSON(
                url, body: try SummaryAPI.chatCompletionsBody(model: model, prompt: prompt),
                headers: headers, timeout: timeout)
            return try SummaryAPI.parseChatCompletions(data)
        }
    }

    /// Sends the conversation and reads the answer as it streams in.
    public func stream(model: String, system: String, messages: [ChatMessage], maxTokens: Int = 4096,
                       update: @escaping @MainActor (ChatProgress) -> Void) async throws -> String {
        let (url, headers) = target
        let body: Data
        let parse: (String) -> ChatStreamEvent
        switch style {
        case .anthropic:
            body = try ChatAPI.anthropicBody(model: model, system: system, messages: messages, maxTokens: maxTokens)
            parse = ChatAPI.parseAnthropic
        case .chatCompletions:
            body = try ChatAPI.chatCompletionsBody(model: model, system: system, messages: messages)
            parse = ChatAPI.parseChatCompletions
        }

        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = body
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 600 { break }
            }
            let text = String(decoding: data, as: UTF8.self)
            // OpenAI streams some models only for verified organizations: ask for the whole answer instead.
            if streamFallback, http.statusCode == 400, text.localizedCaseInsensitiveContains("stream") {
                await update(.status("Waiting for \(name)…"))
                let data = try await HTTP.postJSON(url, body: try ChatAPI.chatCompletionsBody(model: model, system: system,
                                                                                               messages: messages, stream: false),
                                                   headers: headers)
                return try SummaryAPI.parseChatCompletions(data)
            }
            throw ProviderError(message: "HTTP \(http.statusCode) from \(url.host ?? ""): \(text)", httpStatus: http.statusCode)
        }

        var answer = ""
        for try await line in bytes.lines {
            switch parse(line) {
            case .text(let more):
                answer += more
                await update(.text(answer))
            case .error(let message):
                throw ProviderError(message: "\(name): \(message)")
            default:
                break
            }
        }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError(message: "\(name) gave an empty answer.") }
        return text
    }
}

/// Writes a call's summary and action items from the model's answer.
public enum CallSummary {
    /// - Parameters:
    ///   - transcript: the call's transcript text.
    ///   - modelLabel: saved as the call's summary model, e.g. "OpenAI (gpt-5-mini)".
    ///   - complete: sends the prompt to the model and returns its answer.
    public static func write(folder: RecordingFolder, transcript: String, template: String, modelLabel: String,
                             complete: (String) async throws -> String) async throws {
        let meta = folder.loadMeta()
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        let day = dayFormat.string(from: meta?.date ?? Date())
        let prompt = SummaryAPI.renderPrompt(template: template, title: meta?.title ?? "", transcript: transcript)
            + ActionItems.promptSuffix(callDate: day)

        let answer = try await complete(prompt)
        // The action items come as a json block after the summary; without a valid one there are none.
        let (text, items) = ActionItems.split(answer)
        try (text + "\n").write(to: folder.summaryURL, atomically: true, encoding: .utf8)
        try? folder.saveActionItems(ActionItems.merge(items, keepingSentFrom: folder.loadActionItems()))
        folder.updateMeta { $0.summaryModel = modelLabel }
    }
}

public enum ChatProgress {
    /// The answer so far.
    case text(String)
    /// What the provider is doing before it writes.
    case status(String)
}

public struct ChatAnswer {
    public let text: String
    /// About the calls sent, e.g. the ones left out because they didn't fit.
    public let note: String?
    /// The chat title written with the answer, when one was asked for.
    public var title: String?

    public init(text: String, note: String?, title: String? = nil) {
        self.text = text
        self.note = note
        self.title = title
    }
}

/// Answers a question about calls over an HTTP API, with the transcripts in the prompt.
public enum ChatAnswering {
    /// Room kept for the answer, in tokens.
    public static let answerTokens = 4096

    /// What the provider does before it writes, e.g. "Reading 12 calls…".
    public static func readingStatus(_ count: Int) -> String {
        count == 1 ? "Reading the call…" : "Reading \(count) calls…"
    }

    /// - Parameters:
    ///   - contextTokens: the most transcript the model takes, in tokens.
    ///   - folders: the calls to ask about, all with a transcript.
    ///   - past: the earlier messages of the conversation to send.
    public static func answerOverHTTP(endpoint: LLMEndpoint, model: String, contextTokens: Int,
                                      folders: [(call: ChatCall, folder: RecordingFolder)], past: [ChatMessage],
                                      question: String, asksTitle: Bool,
                                      update: @escaping @MainActor (ChatProgress) -> Void) async throws -> ChatAnswer {
        let contexts = folders.compactMap { item -> ChatContextCall? in
            guard let text = try? String(contentsOf: item.folder.transcriptURL, encoding: .utf8) else { return nil }
            return ChatContextCall(call: item.call, transcript: ChatPrompt.transcriptBody(text))
        }
        // Instructions, the list of calls left out, the conversation, the question and the answer.
        let reserved = ChatPrompt.instructions(readsFiles: false).count + 4_000
            + past.reduce(0) { $0 + $1.text.count } + question.count + answerTokens * 4
        let packing = ChatPrompt.pack(contexts, budgetCharacters: max(8_000, contextTokens * 4 - reserved))
        await update(.status(readingStatus(packing.included.count)))
        let text = try await endpoint.stream(model: model, system: ChatPrompt.apiSystem(packing, asksTitle: asksTitle),
                                             messages: past + [ChatMessage(role: .user, text: question)],
                                             maxTokens: answerTokens, update: update)
        var note: String?
        if packing.truncated {
            note = "The transcript was too long for \(endpoint.name): only its start was sent."
        } else if !packing.omitted.isEmpty {
            let left = packing.omitted.count
            note = "Only the \(packing.included.count) most recent calls fit in what \(endpoint.name) takes at once; "
                + (left == 1 ? "1 older call was left out." : "\(left) older calls were left out.")
        }
        return ChatAnswer(text: text, note: note)
    }
}

/// Checks an API key with the cheapest authenticated request each service offers.
public enum KeyCheck {
    public enum Service: Sendable {
        case openAI, groq, openRouter, anthropic, elevenLabs
    }

    public static func request(_ service: Service, key: String) -> URLRequest {
        switch service {
        case .openAI:
            return get("https://api.openai.com/v1/models", bearer: key)
        case .groq:
            return get("https://api.groq.com/openai/v1/models", bearer: key)
        case .openRouter:
            return get("https://openrouter.ai/api/v1/key", bearer: key)
        case .anthropic:
            var request = get("https://api.anthropic.com/v1/models", bearer: nil)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return request
        case .elevenLabs:
            var request = get("https://api.elevenlabs.io/v1/user", bearer: nil)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            return request
        }
    }

    /// What an HTTP status means for the key; `name` is the service as shown to the user.
    public static func result(status: Int, name: String) -> (ok: Bool, message: String) {
        switch status {
        case 200..<300: return (true, "The key works.")
        case 401, 403: return (false, "\(name) refused the key (HTTP \(status)).")
        default: return (false, "\(name) answered HTTP \(status).")
        }
    }

    public static func test(_ service: Service, key: String, name: String) async -> (ok: Bool, message: String) {
        do {
            let (_, response) = try await URLSession.shared.data(for: request(service, key: key))
            return result(status: (response as? HTTPURLResponse)?.statusCode ?? 0, name: name)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private static func get(_ url: String, bearer: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
