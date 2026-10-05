import SwiftUI
import KaikuCore

/// Asks questions about one or more calls; their transcripts are sent to the chat provider.
struct ChatView: View {
    let title: String
    let calls: [CallEntry]

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var answer = ""
    @State private var status: String?
    @State private var note: String?
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty && !sending {
                            Text("Ask anything about \(calls.count == 1 ? "this call" : "these calls").")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(messages) { message in bubble(message.text, mine: message.role == .user) }
                        if sending {
                            if answer.isEmpty { Text(status ?? "Thinking…").foregroundStyle(.secondary) } else { bubble(answer, mine: false) }
                        }
                        if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .onChange(of: messages.count) { proxy.scrollTo("end") }
                .onChange(of: answer) { proxy.scrollTo("end") }
            }
            HStack(alignment: .bottom) {
                TextField("Ask a question", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .textSelection(.enabled)
            .padding(10)
            .background(mine ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        input = ""
        error = nil
        note = nil
        answer = ""
        status = nil
        let past = ChatPrompt.recent(messages)
        messages.append(ChatMessage(role: .user, text: question))
        sending = true
        Task {
            do {
                let kind = PhoneSettings.chatProvider
                let model = PhoneSettings.chatModel(for: kind)
                if kind.requiresModel, model.isEmpty { throw ProviderError(message: "\(kind.displayName) needs a model. Check Settings > AI.") }
                let folders = calls.map { entry in
                    (call: ChatCall(ref: entry.id, path: entry.folder.url.path, title: entry.meta.title,
                                    date: entry.meta.date, duration: entry.meta.durationSeconds),
                     folder: entry.folder)
                }.filter { $0.folder.hasTranscript }
                guard !folders.isEmpty else { throw ProviderError(message: "None of these calls has a transcript yet.") }
                let result = try await ChatAnswering.answerOverHTTP(
                    endpoint: try LLMEndpoint(kind), model: model, contextTokens: kind.chatContextTokens, folders: folders,
                    past: past, question: question, asksTitle: false) { progress in
                    switch progress {
                    case .text(let soFar): answer = soFar
                    case .status(let text): status = text
                    }
                }
                messages.append(ChatMessage(role: .assistant, text: result.text))
                note = result.note
            } catch {
                self.error = error.localizedDescription
            }
            answer = ""
            sending = false
        }
    }
}
