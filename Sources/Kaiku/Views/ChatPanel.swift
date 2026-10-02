import AppKit
import KaikuCore
import PartitiUI
import SwiftUI

extension LibraryItem {
    /// The id the chat cites this call by.
    var chatRef: String { ChatPrompt.ref(forFolderName: folder.url.lastPathComponent) }
}

extension ChatCall {
    init(_ item: LibraryItem) {
        self.init(ref: item.chatRef, path: item.folder.key, title: item.meta.title, date: item.meta.date,
                  duration: item.meta.durationSeconds)
    }
}

/// The library's chat, next to the call detail: the calls it is about, the conversation
/// with citations that open the call at that moment, and the saved chats.
struct ChatPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var chat: ChatModel
    /// Every call in the library.
    let items: [LibraryItem]
    /// The calls selected in the list.
    let selected: [LibraryItem]
    let tags: [String]
    let sources: [String]

    @State private var showHistory = false
    @State private var showCalls = true
    @State private var choosingDates = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var deleteTarget: ChatConversation?
    /// Library calls by chat id.
    @State private var byRef: [String: LibraryItem] = [:]
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private static let end = "end"

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if showHistory {
                history
            } else {
                callsSection
                Hairline()
                conversation
                Hairline()
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.openURL, OpenURLAction { follow($0) })
        .onAppear {
            chat.loadSaved()
            chat.refreshNote()
        }
        .onChange(of: items.map { $0.id + "\u{1F}" + $0.meta.title }, initial: true) { _, _ in
            byRef = Dictionary(items.map { ($0.chatRef, $0) }, uniquingKeysWith: { a, _ in a })
        }
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            presenting: deleteTarget) { target in
            Button("Delete Chat", role: .destructive) { chat.delete(target.id) }
        } message: { _ in
            Text("Its file is removed from the Chats folder. The calls stay as they are.")
        }
    }

    // MARK: Header

    private var header: some View {
        let ink = Ink(scheme)
        return HStack(spacing: PUI.Space.s) {
            Text(showHistory ? "Chats" : (chat.chat.title.isEmpty ? "New Chat" : chat.chat.title))
                .font(PUI.Font.headline)
                .foregroundStyle(ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button { showHistory.toggle() } label: {
                Image(systemName: showHistory ? "bubble.left.and.text.bubble.right" : "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .help(showHistory ? "Back to the chat" : "Saved chats")
            .accessibilityLabel(showHistory ? "Back to the chat" : "Saved chats")
            Button {
                chat.newChat()
                showHistory = false
                focused = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("New chat")
            .accessibilityLabel("New chat")
        }
        .font(PUI.Font.body)
        .padding(.horizontal, PUI.Space.l)
        .padding(.vertical, PUI.Space.m)
    }

    // MARK: Calls

    private var callsSection: some View {
        let ink = Ink(scheme)
        let calls = chat.chat.calls
        return VStack(alignment: .leading, spacing: PUI.Space.s) {
            HStack(spacing: PUI.Space.s) {
                Button { showCalls.toggle() } label: {
                    HStack(spacing: PUI.Space.xs) {
                        Image(systemName: showCalls ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ink.tertiary)
                        Text(calls.isEmpty ? "No calls yet" : calls.count == 1 ? "1 call" : "\(calls.count) calls")
                            .font(PUI.Font.callout.weight(.medium))
                            .foregroundStyle(ink.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(calls.isEmpty)
                Spacer(minLength: 0)
                chooseMenu
            }
            if showCalls && !calls.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: PUI.Space.xs) {
                        ForEach(calls) { callRow($0) }
                    }
                }
                .frame(maxHeight: min(CGFloat(calls.count) * 38, 150))
            }
            if let note = chat.contextNote {
                StatusDot(kind: .warning, text: note)
            }
        }
        .padding(.horizontal, PUI.Space.l)
        .padding(.vertical, PUI.Space.m)
    }

    private func callRow(_ call: ChatCall) -> some View {
        let ink = Ink(scheme)
        let item = byRef[call.ref]
        return HStack(spacing: PUI.Space.s) {
            Button {
                if let item { state.showInLibrary(item.folder, at: nil) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item?.meta.title ?? call.title)
                        .font(PUI.Font.callout)
                        .foregroundStyle(item == nil ? ink.tertiary : ink.primary)
                        .lineLimit(1)
                    Text(call.date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(PUI.Font.caption)
                        .foregroundStyle(ink.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item == nil ? "No longer in the library" : "Show this call")
            Button { chat.remove(call) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(ink.tertiary)
            .help("Remove from this chat")
            .accessibilityLabel("Remove \(call.title) from this chat")
        }
    }

    /// Replaces the calls with the selected ones, a tag, a source or a period.
    private var chooseMenu: some View {
        Menu {
            Button(selected.count > 1 ? "The \(selected.count) Selected Calls" : "The Selected Call") { use(selected) }
                .disabled(selected.isEmpty)
            Button("Add the Selected Calls") { chat.add(chatCalls(selected)) }
                .disabled(selected.isEmpty || chat.chat.calls.isEmpty)
            Divider()
            if !tags.isEmpty {
                Menu("Tag") {
                    ForEach(tags, id: \.self) { tag in
                        Button(tag) { use(items.filter { Tags.contains($0.meta.tags ?? [], tag) }) }
                    }
                }
            }
            if !sources.isEmpty {
                Menu("Source") {
                    ForEach(sources, id: \.self) { source in
                        Button(source) { use(items.filter { Tags.contains([$0.meta.source].compactMap { $0 }, source) }) }
                    }
                }
            }
            Menu("Period") {
                Button("Today") { use(period: ChatPeriod.lastDays(1)) }
                Button("Last 7 Days") { use(period: ChatPeriod.lastDays(7)) }
                Button("Last 30 Days") { use(period: ChatPeriod.lastDays(30)) }
                Divider()
                Button("Choose Dates…") { choosingDates = true }
            }
            if !chat.chat.calls.isEmpty {
                Divider()
                Button("Remove All") { chat.setCalls([]) }
            }
        } label: {
            Label("Choose Calls", systemImage: "plus.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("Choose the calls this chat is about")
        .popover(isPresented: $choosingDates, arrowEdge: .bottom) { datesPicker }
    }

    private var datesPicker: some View {
        VStack(alignment: .leading, spacing: PUI.Space.m) {
            Text("Calls between").font(PUI.Font.headline)
            DatePicker("From", selection: $from, displayedComponents: .date)
            DatePicker("To", selection: $to, displayedComponents: .date)
            HStack {
                Spacer()
                Button("Use These Calls") {
                    use(period: ChatPeriod.range(from: from, to: to))
                    choosingDates = false
                }
                .buttonStyle(PrimaryButtonStyle(height: PUI.Control.small, fullWidth: false))
            }
        }
        .padding(PUI.Space.l)
        .frame(width: 280)
    }

    private func chatCalls(_ list: [LibraryItem]) -> [ChatCall] {
        list.filter { $0.folder.hasTranscript }.map { ChatCall($0) }
    }

    private func use(_ list: [LibraryItem]) {
        let calls = chatCalls(list)
        guard !calls.isEmpty else {
            chat.error = "None of these calls has a transcript yet."
            return
        }
        chat.error = nil
        chat.setCalls(calls)
        showCalls = true
    }

    private func use(period: ClosedRange<Date>) {
        let list = items.filter { period.contains($0.meta.date) }
        guard !list.isEmpty else {
            chat.error = "No calls in that period."
            return
        }
        use(list)
    }

    // MARK: Conversation

    private var conversation: some View {
        let ink = Ink(scheme)
        let titles = titlesByRef
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PUI.Space.xl) {
                    if chat.chat.messages.isEmpty && !chat.isAnswering {
                        LiveEmptyState(symbol: "bubble.left.and.text.bubble.right",
                                       text: chat.chat.calls.isEmpty
                                           ? "Choose the calls to ask about: the selected ones, a tag, a source or a period."
                                           : "Ask anything about these calls. Answers cite the moments they come from; click one to play it.")
                    }
                    ForEach(chat.chat.messages) { message in
                        ChatBubble(message: message, titles: titles)
                            .equatable()
                    }
                    if chat.isAnswering {
                        VStack(alignment: .leading, spacing: PUI.Space.s) {
                            if !chat.partial.isEmpty {
                                MarkdownText(markdown: ChatCitations.linked(chat.partial) { titles[$0] })
                                    .foregroundStyle(ink.primary)
                            }
                            HStack(spacing: PUI.Space.s) {
                                ProgressView().controlSize(.small)
                                Text(chat.partial.isEmpty ? (chat.status ?? "Thinking…") : "Writing…")
                                    .font(PUI.Font.caption)
                                    .foregroundStyle(ink.tertiary)
                            }
                        }
                    }
                    if let error = chat.error {
                        HStack(alignment: .firstTextBaseline, spacing: PUI.Space.s) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ink.orange)
                            Text(error).foregroundStyle(ink.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(PUI.Font.caption)
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(PUI.Space.l)
            }
            .onChange(of: chat.chat.messages) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: chat.partial) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: chat.chat.id) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    /// Call titles for citation links: the library's, then those saved with the chat.
    private var titlesByRef: [String: String] {
        var titles = Dictionary(chat.chat.calls.map { ($0.ref, $0.title) }, uniquingKeysWith: { a, _ in a })
        for (ref, item) in byRef { titles[ref] = item.meta.title }
        return titles
    }

    private var composer: some View {
        let ink = Ink(scheme)
        let accent = AppAccent.kaiku.legible(scheme)
        let kind = AppSettings.chatProvider
        let model = AppSettings.chatModel(for: kind)
        return VStack(alignment: .leading, spacing: PUI.Space.xs) {
            HStack(alignment: .bottom, spacing: PUI.Space.s) {
                TextField("Ask about these calls", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(PUI.Font.body)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(send)
                if chat.isAnswering {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .help("Stop")
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? accent : ink.quaternary)
                    .disabled(!canSend)
                    .help("Ask")
                    .accessibilityLabel("Ask")
                }
            }
            .padding(.leading, PUI.Space.l)
            .padding(.trailing, PUI.Space.xs)
            .padding(.vertical, PUI.Space.s)
            .puiSurface(radius: PUI.Radius.group, elevated: false)
            Button { WindowManager.shared.showSettings(.chat) } label: {
                Text(kind.displayName + (model.isEmpty ? "" : " · \(model)"))
                    .font(PUI.Font.caption)
                    .foregroundStyle(ink.tertiary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Change the chat provider in Settings")
            .padding(.horizontal, PUI.Space.s)
        }
        .padding(PUI.Space.m)
    }

    private var canSend: Bool {
        !chat.isAnswering && !chat.chat.calls.isEmpty && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        chat.send()
    }

    // MARK: History

    private var history: some View {
        let ink = Ink(scheme)
        let accent = AppAccent.kaiku.legible(scheme)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if chat.saved.isEmpty {
                    LiveEmptyState(symbol: "clock", text: "Chats are saved here once you ask something.")
                }
                ForEach(chat.saved) { saved in
                    HStack(spacing: PUI.Space.s) {
                        Button {
                            chat.open(saved.id)
                            showHistory = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saved.title.isEmpty ? "Untitled Chat" : saved.title)
                                    .font(PUI.Font.body)
                                    .foregroundStyle(ink.primary)
                                    .lineLimit(1)
                                Text((saved.calls.count == 1 ? "1 call" : "\(saved.calls.count) calls")
                                     + " · " + saved.updated.formatted(date: .abbreviated, time: .shortened))
                                    .font(PUI.Font.caption)
                                    .foregroundStyle(ink.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { deleteTarget = saved } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(ink.tertiary)
                        .help("Delete this chat")
                        .accessibilityLabel("Delete \(saved.title)")
                    }
                    .padding(.horizontal, PUI.Space.m)
                    .padding(.vertical, PUI.Space.s)
                    .background(saved.id == chat.chat.id ? accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(PUI.Space.m)
        }
    }

    // MARK: Citations

    /// Citation links select their call in the library and play it from that moment.
    private func follow(_ url: URL) -> OpenURLAction.Result {
        guard let citation = ChatCitations.citation(from: url) else { return .systemAction }
        guard let item = byRef[citation.ref] else {
            chat.error = "That call is no longer in the library."
            return .handled
        }
        state.showInLibrary(item.folder, at: citation.time)
        return .handled
    }
}

/// One message. Equatable, so the conversation isn't laid out again while an answer streams in.
private struct ChatBubble: View, Equatable {
    let message: ChatMessage
    let titles: [String: String]
    @Environment(\.colorScheme) private var scheme

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.message == b.message && a.titles == b.titles
    }

    var body: some View {
        let ink = Ink(scheme)
        let accent = AppAccent.kaiku.legible(scheme)
        if message.role == .user {
            Text(message.text)
                .font(PUI.Font.body.weight(.medium))
                .foregroundStyle(ink.primary)
                .textSelection(.enabled)
                .padding(.horizontal, PUI.Space.l)
                .padding(.vertical, PUI.Space.s + 1)
                .puiSurface(radius: PUI.Radius.group, tint: accent, elevated: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, PUI.Space.xxl)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: PUI.Space.xs) {
                MarkdownText(markdown: ChatCitations.linked(message.text) { titles[$0] })
                    .foregroundStyle(ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(PUI.Font.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ink.tertiary)
                .help("Copy this answer")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
