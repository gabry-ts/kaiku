import Foundation
import KaikuCore

/// Answers a question about calls with the chat provider. HTTP APIs get the transcripts
/// in the prompt and stream the answer; command-line tools get the file paths and read them.
@MainActor
enum ChatJob {
    /// Room kept for the answer, in tokens.
    static let answerTokens = ChatAnswering.answerTokens

    typealias Progress = ChatProgress
    typealias Answer = ChatAnswer

    /// What the provider does before it writes, e.g. "Reading 12 calls…".
    static func readingStatus(_ count: Int) -> String { ChatAnswering.readingStatus(count) }

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

        return try await ChatAnswering.answerOverHTTP(
            endpoint: try LLMEndpoint(kind), model: model, contextTokens: kind.chatContextTokens, folders: folders,
            past: past, question: question, asksTitle: asksTitle, update: update)
    }
}
