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

/// The library's chat, in place of the call detail: the calls it is about, the conversation
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

    /// Snapshot rendering shows the calls picker open.
    static var previewShowsCalls = false

    @State private var showHistory = false
    @State private var showCalls = false
    @State private var deleteTarget: ChatConversation?
    /// Library calls by chat id.
    @State private var byRef: [String: LibraryItem] = [:]
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private static let end = "end"
    /// Widest the conversation reads at.
    static let readingWidth: CGFloat = 720

    static let suggestions: [(symbol: String, text: String)] = [
        ("checkmark.seal", "What was decided?"),
        ("checklist", "List the action items"),
        ("list.number", "Summarize in 3 points"),
        ("questionmark.bubble", "Any open questions?"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            conversation
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.openURL, OpenURLAction { follow($0) })
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showHistory.toggle() } label: {
                    Label("Saved Chats", systemImage: "clock.arrow.circlepath")
                }
                .help("Saved chats")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { history }
                Button {
                    chat.newChat()
                    focused = true
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New chat")
            }
        }
        .onAppear {
            chat.loadSaved()
            chat.refreshNote()
            if Self.previewShowsCalls { showCalls = true }
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
        return VStack(alignment: .leading, spacing: PUI.Space.s) {
            Text(chat.chat.title.isEmpty ? "New Chat" : chat.chat.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: PUI.Space.m) {
                callsChip
                if let note = chat.contextNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(PUI.Font.callout)
                        .foregroundStyle(ink.secondary)
                        .labelStyle(NoteLabelStyle(color: ink.orange))
                        .lineLimit(2)
                        .help(note)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, PUI.Space.xl)
        .padding(.bottom, PUI.Space.l)
        .frame(maxWidth: Self.readingWidth + 56, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// "12 calls · Weekly sync, Standup, +10", opening the calls picker.
    private var callsChip: some View {
        let ink = Ink(scheme)
        let calls = chat.chat.calls
        return Button { showCalls.toggle() } label: {
            HStack(spacing: PUI.Space.s) {
                Image(systemName: "waveform")
                    .foregroundStyle(ink.secondary)
                Text(Self.callsSummary(calls.map { byRef[$0.ref]?.meta.title ?? $0.title }))
                    .foregroundStyle(calls.isEmpty ? ink.secondary : ink.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.tertiary)
            }
            .font(PUI.Font.callout)
            .padding(.horizontal, PUI.Space.l - 2)
            .padding(.vertical, PUI.Space.xs + 1)
            .background(Capsule().fill(ink.fill))
            .overlay(Capsule().strokeBorder(ink.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .help("The calls this chat is about")
        .popover(isPresented: $showCalls, arrowEdge: .bottom) {
            ChatCallsPicker(chat: chat, items: items, selected: selected, tags: tags, sources: sources, byRef: byRef)
        }
    }

    /// The count of calls and the first titles.
    static func callsSummary(_ titles: [String]) -> String {
        guard !titles.isEmpty else { return "Choose calls" }
        let count = titles.count == 1 ? "1 call" : "\(titles.count) calls"
        let shown = titles.prefix(2).map { $0.count > 24 ? String($0.prefix(23)).trimmingCharacters(in: .whitespaces) + "…" : $0 }
        let more = titles.count > 2 ? ", +\(titles.count - 2)" : ""
        return count + " · " + shown.joined(separator: ", ") + more
    }

    // MARK: Conversation

    private var conversation: some View {
        let titles = titlesByRef
        let messages = chat.chat.messages
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PUI.Space.xxl) {
                    if messages.isEmpty && !chat.isAnswering {
                        emptyState
                    }
                    ForEach(messages) { message in
                        ChatMessageView(message: message, titles: titles)
                            .equatable()
                    }
                    if chat.isAnswering {
                        VStack(alignment: .leading, spacing: PUI.Space.xl) {
                            ChatProgressRow(step: chat.partial.isEmpty ? (chat.status ?? "Thinking…") : "Writing the answer…",
                                            started: chat.answerStarted ?? Date()) { chat.stop() }
                            if !chat.partial.isEmpty {
                                ChatMarkdown(text: chat.partial, titles: titles)
                            }
                        }
                    }
                    if let error = chat.error {
                        errorRow(error)
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, PUI.Space.xxl)
                .frame(maxWidth: Self.readingWidth + 56, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.chat.messages) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: chat.partial) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: chat.isAnswering) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: chat.chat.id) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        let ink = Ink(scheme)
        let hasCalls = !chat.chat.calls.isEmpty
        return VStack(spacing: PUI.Space.l) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ink.tertiary)
                .padding(.bottom, PUI.Space.xs)
            Text(hasCalls ? "Ask about these calls" : "Chat with your calls")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ink.primary)
            Text(hasCalls
                 ? "Answers cite the moments they come from. Click a citation to play the call from there."
                 : "Choose the calls to ask about: the selected ones, a tag, a source or a period.")
                .font(.body)
                .foregroundStyle(ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if hasCalls {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: PUI.Space.m), GridItem(.flexible(), spacing: PUI.Space.m)],
                          spacing: PUI.Space.m) {
                    ForEach(Self.suggestions, id: \.text) { suggestion in
                        SuggestionButton(symbol: suggestion.symbol, text: suggestion.text) { ask(suggestion.text) }
                    }
                }
                .frame(maxWidth: 480)
                .padding(.top, PUI.Space.l)
            } else {
                Button("Choose Calls…") { showCalls = true }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.regular))
                    .fixedSize()
                    .padding(.top, PUI.Space.s)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private func errorRow(_ error: String) -> some View {
        let ink = Ink(scheme)
        return HStack(alignment: .firstTextBaseline, spacing: PUI.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ink.orange)
            Text(error).foregroundStyle(ink.primary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(PUI.Font.callout)
        .padding(.horizontal, PUI.Space.l)
        .padding(.vertical, PUI.Space.m + 2)
        .background(RoundedRectangle(cornerRadius: PUI.Radius.group, style: .continuous).fill(ink.orange.opacity(0.10)))
    }

    /// Call titles for citation links: the library's, then those saved with the chat.
    private var titlesByRef: [String: String] {
        var titles = Dictionary(chat.chat.calls.map { ($0.ref, $0.title) }, uniquingKeysWith: { a, _ in a })
        for (ref, item) in byRef { titles[ref] = item.meta.title }
        return titles
    }

    // MARK: Composer

    private var composer: some View {
        let ink = Ink(scheme)
        let accent = AppAccent.kaiku.legible(scheme)
        return VStack(alignment: .leading, spacing: PUI.Space.s) {
            TextField(chat.chat.calls.isEmpty ? "Choose calls to ask about" : "Ask about these calls…",
                      text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, PUI.Space.xs)
            HStack(spacing: PUI.Space.m) {
                ChatProviderMenu(chat: chat)
                Spacer(minLength: 0)
                if chat.isAnswering {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ink.primary)
                    .help("Stop")
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? accent : ink.quaternary)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Ask")
                    .accessibilityLabel("Ask")
                }
            }
        }
        .padding(.horizontal, PUI.Space.l)
        .padding(.top, PUI.Space.l)
        .padding(.bottom, PUI.Space.m)
        .puiSurface(radius: 16)
        .padding(.horizontal, 28)
        .padding(.top, PUI.Space.s)
        .padding(.bottom, PUI.Space.xl)
        .frame(maxWidth: Self.readingWidth + 56)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !chat.isAnswering && !chat.chat.calls.isEmpty && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        chat.send()
    }

    private func ask(_ question: String) {
        guard !chat.isAnswering else { return }
        chat.draft = question
        send()
    }

    // MARK: History

    private var history: some View {
        let ink = Ink(scheme)
        let accent = AppAccent.kaiku.legible(scheme)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Saved Chats")
                .font(PUI.Font.headline)
                .foregroundStyle(ink.primary)
                .padding(.horizontal, PUI.Space.xl)
                .padding(.top, PUI.Space.l)
                .padding(.bottom, PUI.Space.s)
            if chat.saved.isEmpty {
                Text("Chats are saved here once you ask something.")
                    .font(PUI.Font.callout)
                    .foregroundStyle(ink.secondary)
                    .padding(.horizontal, PUI.Space.xl)
                    .padding(.bottom, PUI.Space.xl)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
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
                                            .font(PUI.Font.callout)
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
                            .background(saved.id == chat.chat.id ? accent.opacity(0.10) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: PUI.Radius.row, style: .continuous))
                        }
                    }
                    .padding(.horizontal, PUI.Space.m)
                    .padding(.bottom, PUI.Space.m)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 320)
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

/// An icon in the note color, next to its text.
private struct NoteLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PUI.Space.xs) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}

/// A question to start the chat with.
private struct SuggestionButton: View {
    let symbol: String
    let text: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        Button(action: action) {
            HStack(spacing: PUI.Space.m) {
                Image(systemName: symbol)
                    .foregroundStyle(ink.secondary)
                    .frame(width: 18)
                Text(text)
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.body)
            .padding(.horizontal, PUI.Space.l)
            .padding(.vertical, PUI.Space.m + 3)
            .background(RoundedRectangle(cornerRadius: PUI.Radius.group, style: .continuous)
                .fill(hovering ? ink.strongFill : ink.fill))
            .overlay(RoundedRectangle(cornerRadius: PUI.Radius.group, style: .continuous).strokeBorder(ink.hairline))
            .contentShape(RoundedRectangle(cornerRadius: PUI.Radius.group, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// While an answer is written: what the provider does, for how long, and Stop.
private struct ChatProgressRow: View {
    let step: String
    let started: Date
    let stop: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        HStack(spacing: PUI.Space.m + 2) {
            ProgressView().controlSize(.small)
            Text(step)
                .font(.body.weight(.medium))
                .foregroundStyle(ink.primary)
                .lineLimit(1)
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text("\(max(0, Int(context.date.timeIntervalSince(started))))s")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(ink.tertiary)
            }
            Spacer(minLength: PUI.Space.m)
            Button("Stop", action: stop)
                .controlSize(.small)
                .help("Stop the answer")
        }
        .padding(.leading, PUI.Space.l)
        .padding(.trailing, PUI.Space.m)
        .padding(.vertical, PUI.Space.m)
        .background(RoundedRectangle(cornerRadius: PUI.Radius.group, style: .continuous).fill(ink.fill))
        .overlay(RoundedRectangle(cornerRadius: PUI.Radius.group, style: .continuous).strokeBorder(ink.hairline))
    }
}

/// The provider and model answering, as a small menu in the composer. Changes the chat settings.
private struct ChatProviderMenu: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject private var catalog = ModelCatalog.shared
    @Environment(\.colorScheme) private var scheme

    /// Longest model list shown in the menu; longer ones are chosen in Settings.
    private static let longestList = 30

    var body: some View {
        let ink = Ink(scheme)
        let kind = AppSettings.chatProvider
        let model = AppSettings.chatModel(for: kind)
        Menu {
            Picker("Provider", selection: Binding(get: { kind }, set: { chat.setProvider($0) })) {
                ForEach(SummaryProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            models(kind: kind, model: model)
            Divider()
            Button("Chat Settings…") { WindowManager.shared.showSettings(.ai, anchor: "chat") }
        } label: {
            HStack(spacing: PUI.Space.xs) {
                Text(kind.displayName + (model.isEmpty ? "" : " · \(model)"))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(PUI.Font.callout)
            .foregroundStyle(ink.secondary)
            .padding(.horizontal, PUI.Space.s)
            .padding(.vertical, PUI.Space.xxs + 1)
            .background(Capsule().fill(ink.fill))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Who answers, also in Settings > AI > Chat")
        .task(id: kind) { await catalog.load(kind) }
    }

    @ViewBuilder private func models(kind: SummaryProviderKind, model: String) -> some View {
        let listed = catalog.models[kind] ?? []
        let names = ([model].filter { !$0.isEmpty } + (listed.count <= Self.longestList ? listed : []))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !names.isEmpty || kind.cli != nil || !kind.defaultModel.isEmpty {
            Picker("Model", selection: Binding(get: { model }, set: { chat.setModel($0, for: kind) })) {
                if kind.cli != nil { Text("CLI Default").tag("") }
                if !kind.defaultModel.isEmpty, !names.contains(kind.defaultModel) {
                    Text(kind.defaultModel).tag(kind.defaultModel)
                }
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
        }
    }
}

// MARK: - Calls picker

/// The calls of a chat, each removable, and ways to choose them.
struct ChatCallsPicker: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var chat: ChatModel
    let items: [LibraryItem]
    let selected: [LibraryItem]
    let tags: [String]
    let sources: [String]
    let byRef: [String: LibraryItem]

    @State private var choosingDates = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var problem: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        let calls = chat.chat.calls
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(calls.isEmpty ? "No calls yet" : calls.count == 1 ? "1 call" : "\(calls.count) calls")
                    .font(PUI.Font.headline)
                    .foregroundStyle(ink.primary)
                Spacer()
                if !calls.isEmpty {
                    Button("Remove All") { chat.setCalls([]) }
                        .buttonStyle(.borderless)
                        .font(PUI.Font.callout)
                        .foregroundStyle(ink.secondary)
                }
            }
            .padding(.horizontal, PUI.Space.xl)
            .padding(.top, PUI.Space.l)
            .padding(.bottom, PUI.Space.s)
            if !calls.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(calls) { callRow($0) }
                    }
                    .padding(.horizontal, PUI.Space.m)
                }
                .frame(maxHeight: min(CGFloat(calls.count) * 42 + 4, 252))
            }
            Hairline().padding(.vertical, PUI.Space.s)
            Text("Choose Calls")
                .font(PUI.Font.label)
                .foregroundStyle(ink.secondary)
                .padding(.horizontal, PUI.Space.xl)
                .padding(.vertical, PUI.Space.xs)
            VStack(alignment: .leading, spacing: 1) {
                option(selected.count == 1 ? "The Selected Call" : selected.isEmpty ? "The Selected Calls" : "The \(selected.count) Selected Calls",
                       symbol: "checkmark.circle", disabled: selected.isEmpty) { use(selected) }
                option(selected.count == 1 ? "Add the Selected Call" : "Add the Selected Calls", symbol: "plus.circle",
                       disabled: selected.isEmpty || calls.isEmpty) {
                    chat.add(chatCalls(selected))
                }
                if !tags.isEmpty {
                    menuOption("By Tag", symbol: "tag", values: tags) { tag in
                        use(items.filter { Tags.contains($0.meta.tags ?? [], tag) })
                    }
                }
                if !sources.isEmpty {
                    menuOption("By Source", symbol: "dot.radiowaves.left.and.right", values: sources) { source in
                        use(items.filter { Tags.contains([$0.meta.source].compactMap { $0 }, source) })
                    }
                }
                option("Last 7 Days", symbol: "calendar") { use(period: ChatPeriod.lastDays(7)) }
                option("Last 30 Days", symbol: "calendar") { use(period: ChatPeriod.lastDays(30)) }
                option("Custom Range…", symbol: "calendar.badge.clock") { choosingDates.toggle() }
                if choosingDates { datesPicker }
            }
            .padding(.horizontal, PUI.Space.m)
            if let problem {
                Text(problem)
                    .font(PUI.Font.callout)
                    .foregroundStyle(ink.orange)
                    .padding(.horizontal, PUI.Space.xl)
                    .padding(.top, PUI.Space.s)
            }
            Spacer().frame(height: PUI.Space.m)
        }
        .frame(width: 340)
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
                        .font(PUI.Font.body)
                        .foregroundStyle(item == nil ? ink.tertiary : ink.primary)
                        .lineLimit(1)
                    Text(call.date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(PUI.Font.callout)
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
        .padding(.horizontal, PUI.Space.m)
        .padding(.vertical, PUI.Space.xs + 1)
    }

    private func optionLabel(_ title: String, symbol: String, chevron: Bool = false) -> some View {
        let ink = Ink(scheme)
        return HStack(spacing: PUI.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(ink.secondary)
                .frame(width: 18)
            Text(title).foregroundStyle(ink.primary)
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.tertiary)
            }
        }
        .font(PUI.Font.body)
        .padding(.horizontal, PUI.Space.m)
        .padding(.vertical, PUI.Space.s)
        .contentShape(Rectangle())
    }

    private func option(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { optionLabel(title, symbol: symbol) }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
    }

    private func menuOption(_ title: String, symbol: String, values: [String], pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in Button(value) { pick(value) } }
        } label: {
            optionLabel(title, symbol: symbol, chevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var datesPicker: some View {
        VStack(alignment: .leading, spacing: PUI.Space.s) {
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
        .font(PUI.Font.body)
        .padding(.horizontal, PUI.Space.m + 26)
        .padding(.vertical, PUI.Space.s)
    }

    private func chatCalls(_ list: [LibraryItem]) -> [ChatCall] {
        list.filter { $0.folder.hasTranscript }.map { ChatCall($0) }
    }

    private func use(_ list: [LibraryItem]) {
        let calls = chatCalls(list)
        guard !calls.isEmpty else {
            problem = "None of these calls has a transcript yet."
            return
        }
        problem = nil
        chat.error = nil
        chat.setCalls(calls)
    }

    private func use(period: ClosedRange<Date>) {
        let list = items.filter { period.contains($0.meta.date) }
        guard !list.isEmpty else {
            problem = "No calls in that period."
            return
        }
        use(list)
    }
}

// MARK: - Messages

/// One message: a question in a bubble on the right, an answer across the column.
/// Equatable, so the conversation isn't laid out again while an answer streams in.
private struct ChatMessageView: View, Equatable {
    let message: ChatMessage
    let titles: [String: String]
    @Environment(\.colorScheme) private var scheme

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.message == b.message && a.titles == b.titles
    }

    var body: some View {
        let ink = Ink(scheme)
        if message.role == .user {
            Text(message.text)
                .font(.body)
                .foregroundStyle(ink.primary)
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(.horizontal, PUI.Space.l + 2)
                .padding(.vertical, PUI.Space.m + 1)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ink.strongFill))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 96)
        } else {
            VStack(alignment: .leading, spacing: PUI.Space.m) {
                ChatMarkdown(text: message.text, titles: titles)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(PUI.Font.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ink.tertiary)
                .help("Copy this answer")
                .accessibilityLabel("Copy this answer")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An answer's Markdown: headings, lists, quotes, code and inline styles, with citations as
/// small accent chips that open the call at that moment.
struct ChatMarkdown: View {
    let text: String
    let titles: [String: String]
    @Environment(\.colorScheme) private var scheme

    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case item(marker: String, text: String, indent: Int)
        case quote(String)
        case code(String)
        case rule
    }

    var body: some View {
        let ink = Ink(scheme)
        let linked = ChatCitations.linked(text, parentheses: false) { titles[$0] }
        let blocks = Self.blocks(linked)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(block, ink: ink)
                    .padding(.top, Self.extraSpace(before: block, after: index > 0 ? blocks[index - 1] : nil))
            }
        }
        .font(.body)
        .lineSpacing(3)
        .foregroundStyle(ink.primary)
        .tint(AppAccent.kaiku.legible(scheme))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Headings get room above; list items sit closer together.
    private static func extraSpace(before block: Block, after previous: Block?) -> CGFloat {
        guard let previous else { return 0 }
        switch (previous, block) {
        case (_, .heading): return 8
        case (.item, .item): return -5
        default: return 0
        }
    }

    @ViewBuilder private func view(_ block: Block, ink: Ink) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text, ink: ink))
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .body.weight(.semibold))
        case .paragraph(let text):
            Text(inline(text, ink: ink))
        case .item(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: PUI.Space.s) {
                Text(marker)
                    .foregroundStyle(ink.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 12, alignment: marker == "•" ? .center : .trailing)
                Text(inline(text, ink: ink))
            }
            .padding(.leading, CGFloat(indent) * 18 + 2)
        case .quote(let text):
            Text(inline(text, ink: ink))
                .foregroundStyle(ink.secondary)
                .padding(.leading, PUI.Space.l)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(ink.quaternary).frame(width: 3)
                }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .padding(PUI.Space.l)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PUI.Radius.row, style: .continuous).fill(ink.fill))
            .overlay(RoundedRectangle(cornerRadius: PUI.Radius.row, style: .continuous).strokeBorder(ink.hairline))
        case .rule:
            Hairline()
        }
    }

    /// Inline Markdown, with citation links as chips and code in a monospaced font.
    private func inline(_ source: String, ink: Ink) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out = (try? AttributedString(markdown: Self.padCitations(source), options: options)) ?? AttributedString(source)
        let accent = AppAccent.kaiku.legible(scheme)
        for run in out.runs {
            if let link = run.link, link.scheme == ChatCitations.scheme {
                out[run.range].font = .system(size: 11, weight: .medium).monospacedDigit()
                out[run.range].foregroundColor = accent
                out[run.range].backgroundColor = accent.opacity(ink.isDark ? 0.16 : 0.10)
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                out[run.range].font = .system(size: 12, design: .monospaced)
                out[run.range].backgroundColor = ink.fill
            }
        }
        return out
    }

    private static let citationLink = try! NSRegularExpression(pattern: #"\[([^\[\]]+)\]\((\#(ChatCitations.scheme)://[^)\s]+)\)"#)

    /// Non-breaking spaces inside each citation label pad its chip.
    /// Long call titles are cut to their first words, so a chip stays short.
    static func padCitations(_ text: String) -> String {
        var out = text
        for match in citationLink.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: out), let label = Range(match.range(at: 1), in: out),
                  let link = Range(match.range(at: 2), in: out) else { continue }
            var parts = out[label].components(separatedBy: " · ")
            parts[0] = chipTitle(parts[0])
            let text = parts.joined(separator: " · ").replacingOccurrences(of: " ", with: "\u{00A0}")
            out.replaceSubrange(whole, with: "[\u{00A0}\(text)\u{00A0}](\(out[link]))")
        }
        return out
    }

    private static func chipTitle(_ title: String) -> String {
        let longest = 18
        guard title.count > longest else { return title }
        var kept = ""
        for word in title.replacingOccurrences(of: "…", with: "").split(separator: " ") {
            guard kept.count + word.count + 1 <= longest else { break }
            kept += kept.isEmpty ? String(word) : " " + word
        }
        // Not on a short word like "with" or "and".
        var words = kept.split(separator: " ")
        while words.count > 1, let last = words.last, ["a", "an", "and", "the", "of", "for", "to", "in", "on", "with", "at", "by"].contains(last.lowercased()) { words.removeLast() }
        kept = words.joined(separator: " ")
        return (kept.isEmpty ? String(title.prefix(longest - 1)) : kept.trimmingCharacters(in: .punctuationCharacters)) + "…"
    }

    /// The blocks of a Markdown answer, line by line.
    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            let indent = (raw.prefix { $0 == " " }.count) / 2
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" || line == "___" {
                flush()
                blocks.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                blocks.append(.item(marker: "•", text: String(line.dropFirst(2)), indent: indent))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].count <= 3, line[..<dot].allSatisfy(\.isNumber),
                      !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.item(marker: String(line[...dot]),
                                    text: line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces), indent: indent))
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
