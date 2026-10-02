import Foundation
import KaikuCore

/// The chat of the library: the conversation shown, the saved ones and the answer being
/// written. Lives with the app, so an answer keeps coming while the library is closed.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var chat = ChatConversation()
    /// Saved chats, the latest first.
    @Published private(set) var saved: [ChatConversation] = []
    /// The question being typed; given back when its answer fails.
    @Published var draft = ""
    /// The answer so far, while one is being written.
    @Published private(set) var partial = ""
    /// What the provider is doing before it writes.
    @Published private(set) var status: String?
    @Published private(set) var isAnswering = false
    @Published var error: String?
    /// About the calls sent, e.g. that some don't fit or have no transcript.
    @Published private(set) var contextNote: String?

    private var task: Task<Void, Never>?
    private var store: ChatStore { ChatStore(directory: AppSettings.chatsFolder) }

    func loadSaved() {
        saved = store.all()
    }

    /// Starts a chat about `calls`, or gives them to the current one when nothing was asked yet.
    func start(with calls: [ChatCall]) {
        if !chat.messages.isEmpty || isAnswering { newChat() }
        setCalls(calls)
    }

    func newChat() {
        stop()
        chat = ChatConversation()
        error = nil
        refreshNote()
    }

    func open(_ id: UUID) {
        guard id != chat.id, let found = saved.first(where: { $0.id == id }) else { return }
        stop()
        chat = found
        error = nil
        refreshNote()
    }

    func delete(_ id: UUID) {
        if chat.id == id { newChat() }
        do { try store.delete(id) } catch { self.error = error.localizedDescription }
        loadSaved()
    }

    /// The calls the chat is about, the latest first.
    func setCalls(_ calls: [ChatCall]) {
        var seen = Set<String>()
        chat.calls = calls.filter { seen.insert($0.ref).inserted }.sorted { $0.date > $1.date }
        if !chat.messages.isEmpty { save() }
        refreshNote()
    }

    func add(_ calls: [ChatCall]) {
        setCalls(chat.calls + calls)
    }

    func remove(_ call: ChatCall) {
        setCalls(chat.calls.filter { $0.ref != call.ref })
    }

    /// Asks the draft with the provider chosen in Settings > Chat.
    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        guard !chat.calls.isEmpty else {
            error = "Choose the calls to ask about first."
            return
        }
        let kind = AppSettings.chatProvider
        if let problem = kind.problem {
            error = "\(problem) Check Settings > Chat."
            return
        }
        let model = AppSettings.chatModel(for: kind)
        let history = chat.messages
        let calls = chat.calls
        let id = chat.id
        draft = ""
        error = nil
        chat.messages.append(ChatMessage(role: .user, text: question))
        if chat.title.isEmpty { chat.title = ChatConversation.title(from: question) }
        isAnswering = true
        partial = ""
        status = "Waiting for \(kind.displayName)…"
        task = Task { [weak self] in
            let result: Result<ChatJob.Answer, Error>
            do {
                result = .success(try await ChatJob.answer(kind: kind, model: model, calls: calls, history: history,
                                                           question: question) { [weak self] progress in
                    guard let self, self.chat.id == id, self.isAnswering else { return }
                    switch progress {
                    case .text(let text): self.partial = text
                    case .status(let text): self.status = text
                    }
                })
            } catch {
                result = .failure(error)
            }
            self?.finish(result, chatID: id, question: question, kind: kind, model: model)
        }
    }

    /// Stops the answer being written, keeping what came so far.
    func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        isAnswering = false
        if !partial.isEmpty {
            chat.messages.append(ChatMessage(role: .assistant, text: partial + "\n\n_Stopped._"))
            save()
        } else if let last = chat.messages.last, last.role == .user {
            chat.messages.removeLast()
            if draft.isEmpty { draft = last.text }
        }
        partial = ""
        status = nil
    }

    private func finish(_ result: Result<ChatJob.Answer, Error>, chatID: UUID, question: String,
                        kind: SummaryProviderKind, model: String) {
        // Stopped, or another chat was opened meanwhile.
        guard task != nil, chat.id == chatID else { return }
        task = nil
        isAnswering = false
        partial = ""
        status = nil
        switch result {
        case .success(let answer):
            chat.messages.append(ChatMessage(role: .assistant, text: answer.text))
            chat.provider = kind.rawValue
            chat.model = model
            save()
            contextNote = answer.note ?? Self.note(for: chat.calls, kind: kind)
        case .failure(let error):
            if chat.messages.last?.role == .user { chat.messages.removeLast() }
            if draft.isEmpty { draft = question }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private func save() {
        chat.updated = Date()
        do {
            try store.save(chat)
        } catch {
            self.error = "Couldn't save the chat: \(error.localizedDescription)"
        }
        loadSaved()
    }

    /// Updates the note on the calls for the provider chosen now.
    func refreshNote() {
        contextNote = Self.note(for: chat.calls, kind: AppSettings.chatProvider)
    }

    /// Calls without a transcript, and for HTTP APIs whether the transcripts fit, from their size.
    static func note(for calls: [ChatCall], kind: SummaryProviderKind) -> String? {
        let folders = calls.map { RecordingFolder(url: URL(fileURLWithPath: $0.path, isDirectory: true)) }
        var parts: [String] = []
        let missing = folders.filter { !$0.hasTranscript }.count
        if missing > 0 {
            parts.append(missing == 1 ? "1 call has no transcript yet and is left out." : "\(missing) calls have no transcript yet and are left out.")
        }
        if kind.cli == nil {
            let bytes = folders.reduce(Int64(0)) { $0 + RecordingFolder.fileSize($1.transcriptURL) }
            let tokens = ChatPrompt.estimatedTokens(characters: Int(bytes))
            if tokens > kind.chatContextTokens - ChatJob.answerTokens {
                parts.append("About \(tokens.formatted()) tokens of transcripts, more than \(kind.displayName) takes at once (~\(kind.chatContextTokens.formatted())): only the most recent calls that fit are sent.")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
