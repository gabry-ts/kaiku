import Foundation
import KaikuCore

/// Answers a question about calls with the chat provider. HTTP APIs get the transcripts
/// in the prompt and stream the answer; command-line tools get the file paths and read them.
@MainActor
enum ChatJob {
    /// Room kept for the answer, in tokens.
    static let answerTokens = 4096

    enum Progress {
        /// The answer so far.
        case text(String)
        /// What the provider is doing before it writes.
        case status(String)
    }

    struct Answer {
        let text: String
        /// About the calls sent, e.g. the ones left out because they didn't fit.
        let note: String?
        /// The chat title written with the answer, when one was asked for.
        var title: String?
    }

    /// What the provider does before it writes, e.g. "Reading 12 calls…".
    static func readingStatus(_ count: Int) -> String {
        count == 1 ? "Reading the call…" : "Reading \(count) calls…"
    }

    /// - Parameter asksTitle: also asks for a short title of the chat, split off the answer.
    static func answer(kind: SummaryProviderKind, model: String, calls: [ChatCall], history: [ChatMessage], question: String,
                       asksTitle: Bool = false, update: @escaping @MainActor (Progress) -> Void) async throws -> Answer {
        let answer = try await text(kind: kind, model: model, calls: calls, history: history, question: question,
                                    asksTitle: asksTitle) { progress in
            if case .text(let soFar) = progress { update(.text(ChatTitle.hidingTitle(soFar))) } else { update(progress) }
        }
        guard asksTitle else { return answer }
        let split = ChatTitle.split(answer.text)
        return Answer(text: split.text, note: answer.note, title: split.title)
    }

    private static func text(kind: SummaryProviderKind, model: String, calls: [ChatCall], history: [ChatMessage], question: String,
                             asksTitle: Bool, update: @escaping @MainActor (Progress) -> Void) async throws -> Answer {
        if kind.requiresModel, model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ProviderError(message: "\(kind.displayName) needs a model. Check Settings > AI > Chat.")
        }
        let past = ChatPrompt.recent(history)
        let folders = calls.map { (call: $0, folder: RecordingFolder(url: URL(fileURLWithPath: $0.path, isDirectory: true))) }
            .filter { $0.folder.hasTranscript }
        guard !folders.isEmpty else { throw ProviderError(message: "None of these calls has a transcript yet.") }

        if let cli = kind.cli {
            let files = folders.map {
                ChatCallFiles(call: $0.call, transcriptPath: $0.folder.transcriptURL.path,
                              summaryPath: $0.folder.hasSummary ? $0.folder.summaryURL.path : nil)
            }
            let prompt = ChatPrompt.cliPrompt(files: files, history: past, question: question, asksTitle: asksTitle)
            update(.status(readingStatus(folders.count)))
            let text = try await CLIProviders.chat(cli, name: kind.displayName, model: model, prompt: prompt,
                                                   // OpenCode reads files inside the folder it runs in.
                                                   workDir: cli == .opencode ? AppSettings.baseFolder : nil,
                                                   readableDirs: folders.map { $0.folder.url.path }, timeout: 600) { event in
                switch event {
                case .answer(let soFar): update(.text(soFar))
                case .tool: update(.status(readingStatus(folders.count)))
                default: break
                }
            }
            return Answer(text: text, note: nil)
        }

        let contexts = folders.compactMap { item -> ChatContextCall? in
            guard let text = try? String(contentsOf: item.folder.transcriptURL, encoding: .utf8) else { return nil }
            return ChatContextCall(call: item.call, transcript: ChatPrompt.transcriptBody(text))
        }
        // Instructions, the list of calls left out, the conversation, the question and the answer.
        let reserved = ChatPrompt.instructions(readsFiles: false).count + 4_000
            + past.reduce(0) { $0 + $1.text.count } + question.count + answerTokens * 4
        let packing = ChatPrompt.pack(contexts, budgetCharacters: max(8_000, kind.chatContextTokens * 4 - reserved))
        update(.status(readingStatus(packing.included.count)))
        let text = try await stream(kind: kind, model: model, system: ChatPrompt.apiSystem(packing, asksTitle: asksTitle),
                                    messages: past + [ChatMessage(role: .user, text: question)], update: update)
        var note: String?
        if packing.truncated {
            note = "The transcript was too long for \(kind.displayName): only its start was sent."
        } else if !packing.omitted.isEmpty {
            let left = packing.omitted.count
            note = "Only the \(packing.included.count) most recent calls fit in what \(kind.displayName) takes at once; "
                + (left == 1 ? "1 older call was left out." : "\(left) older calls were left out.")
        }
        return Answer(text: text, note: note)
    }

    /// Sends the conversation to an HTTP API and reads its answer as it streams in.
    private static func stream(kind: SummaryProviderKind, model: String, system: String, messages: [ChatMessage],
                               update: @escaping @MainActor (Progress) -> Void) async throws -> String {
        let key = kind.apiKey ?? ""
        let url: URL
        let body: Data
        let headers: [String: String]
        let parse: (String) -> ChatStreamEvent
        switch kind {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            body = try ChatAPI.anthropicBody(model: model, system: system, messages: messages, maxTokens: answerTokens)
            headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
            parse = ChatAPI.parseAnthropic
        case .openAI, .groq, .openRouter, .ollama, .custom:
            guard let base = kind.chatCompletionsBase else { throw ProviderError(message: "No \(kind.displayName) server address yet.") }
            url = URL(string: base + "/chat/completions")!
            body = try ChatAPI.chatCompletionsBody(model: model, system: system, messages: messages)
            // Local servers usually take no key.
            headers = key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"]
            parse = ChatAPI.parseChatCompletions
        case .claudeCode, .codex, .opencode:
            throw ProviderError(message: "\(kind.displayName) runs as a command-line tool.")
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
            if kind == .openAI, http.statusCode == 400, text.localizedCaseInsensitiveContains("stream") {
                update(.status("Waiting for \(kind.displayName)…"))
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
                update(.text(answer))
            case .error(let message):
                throw ProviderError(message: "\(kind.displayName): \(message)")
            default:
                break
            }
        }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError(message: "\(kind.displayName) gave an empty answer.") }
        return text
    }
}
