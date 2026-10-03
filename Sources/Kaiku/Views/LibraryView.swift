import AppKit
import AVFoundation
import PartitiUI
import SwiftUI
import KaikuCore

struct LibraryItem: Identifiable, Hashable {
    let folder: RecordingFolder
    let meta: RecordingMeta
    let transcript: String?
    var id: String { folder.id }

    static func == (a: LibraryItem, b: LibraryItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func loadAll(base: URL = AppSettings.baseFolder) -> [LibraryItem] {
        RecordingFolder.scan(base: base)
            .compactMap { f in
                guard let m = f.loadMeta() else { return nil }
                return LibraryItem(folder: f, meta: m, transcript: try? String(contentsOf: f.transcriptURL, encoding: .utf8))
            }
            .sorted { $0.meta.date > $1.meta.date }
    }
}

/// Dialog-backed actions are requested here and presented by LibraryView,
/// so they also work from the list context menu and the toolbar.
enum PendingAction {
    case deleteCalls([RecordingFolder])
    case deleteAudio([RecordingFolder])
    case renameSpeakers(RecordingFolder, RecordingMeta)
    case addTag([RecordingFolder])
    case chat([RecordingFolder])
}

/// What the detail column of the library shows.
enum LibraryDetailMode: String {
    case call, chat
}

struct LibraryView: View {
    /// Snapshot rendering opens calls that have a summary on the Summary tab.
    static var preferSummaryTab = false

    @EnvironmentObject var state: AppState
    @State private var items: [LibraryItem] = []
    @State private var search = ""
    @State private var tagFilter: String?
    @State private var sourceFilter: String?
    @State private var selection: Set<String> = []
    @State private var deleteCallTargets: [RecordingFolder] = []
    @State private var deleteAudioTargets: [RecordingFolder] = []
    @State private var tagTargets: [RecordingFolder] = []
    @State private var speakersTarget: LibraryItem?
    @State private var errorMessage: String?
    @ObservedObject private var nav = AppNavigation.shared
    private var mode: LibraryDetailMode {
        get { nav.mode }
        nonmutating set { nav.mode = newValue }
    }
    /// Search by meaning instead of by the words typed.
    @State private var smartSearch = false
    /// Smart search switched on, here or in Settings > General.
    @AppStorage(Keys.smartSearchUsed) private var smartSearchOn = false

    /// Smart search is on and something was typed: passages are listed instead of calls.
    private var showingPassages: Bool {
        smartSearch && !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var allTags: [String] {
        Tags.byRecency(items.map { ($0.meta.date, $0.meta.tags ?? []) })
    }

    /// Sources of the recordings, most recently used first.
    private var allSources: [String] {
        Tags.byRecency(items.map { ($0.meta.date, [$0.meta.source].compactMap { $0 }) })
    }

    private var filtered: [LibraryItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            let tags = item.meta.tags ?? []
            if let tagFilter, !Tags.contains(tags, tagFilter) { return false }
            if let sourceFilter, !Tags.contains([item.meta.source].compactMap { $0 }, sourceFilter) { return false }
            guard !q.isEmpty, !smartSearch else { return true }
            return item.meta.title.localizedCaseInsensitiveContains(q)
                || tags.contains { $0.localizedCaseInsensitiveContains(q) }
                || (item.meta.source?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.transcript?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var selectedItems: [LibraryItem] { items.filter { selection.contains($0.id) } }

    private var groups: [(title: String, items: [LibraryItem])] {
        let cal = Calendar.current
        let now = Date()
        func group(_ d: Date) -> Int {
            if cal.isDateInToday(d) { return 0 }
            if cal.isDateInYesterday(d) { return 1 }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 99
            if days < 7 { return 2 }
            if days < 30 { return 3 }
            return 4
        }
        let names = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Earlier"]
        let dict = Dictionary(grouping: filtered) { group($0.meta.date) }
        return dict.keys.sorted().map { (names[$0], dict[$0]!) }
    }

    /// The call list with its filters and smart search results.
    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        LibraryRow(item: item, busy: state.isBusy(item.folder))
                            .tag(item.id)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: items.filter { ids.contains($0.id) })
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 1) {
                    MainSidebarButton(title: "Calls", symbol: "phone.fill", selected: mode == .call) { mode = .call }
                    MainSidebarButton(title: "Chat", symbol: "bubble.left.and.text.bubble.right.fill", selected: mode == .chat) { mode = .chat }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                smartSearchBar
                if !allTags.isEmpty { filterBar(allTags, selection: $tagFilter) }
                if !allSources.isEmpty { filterBar(allSources, selection: $sourceFilter, symbol: "dot.radiowaves.left.and.right") }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                MainSidebarButton(title: "Settings", symbol: "gearshape") {
                    WindowManager.shared.showSettings()
                }
                .help("Settings (⌘,)")
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search calls, tags, sources and transcripts")
        .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        .overlay {
            if items.isEmpty {
                Text("No recordings").foregroundStyle(.tertiary)
            } else if showingPassages {
                SmartResults(semantic: state.semantic, selected: selection) { hit in
                    state.showInLibrary(hit.folder, at: hit.passage.start)
                }
            } else if filtered.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No Matching Calls", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text([tagFilter, sourceFilter].compactMap { $0 }.joined(separator: " · ")))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }

    /// The chat, the selected call(s), or an empty state.
    @ViewBuilder private var detailColumn: some View {
        if mode == .chat {
            ChatPanel(chat: state.chat, items: items, selected: selectedItems, tags: allTags, sources: allSources)
        } else if selectedItems.count > 1 {
            MultiSelectionView(items: selectedItems, request: requestAction)
        } else if let item = selectedItems.first {
            RecordingDetail(item: item, search: search, knownTags: allTags, request: requestAction)
                .id(item.id)
        } else if items.isEmpty {
            ContentUnavailableView {
                Label("No Recordings Yet", systemImage: "waveform.and.mic")
            } description: {
                Text(Shortcuts.combo(for: .record).map { "Start one from the menu bar or press \($0.display) from any app." }
                     ?? "Start one from the menu bar. Calls are saved in \(AppSettings.baseFolderDisplayPath).")
            } actions: {
                Button("Start Recording") { state.requestStart() }
                    .buttonStyle(PrimaryButtonStyle(height: PUI.Control.regular, fullWidth: false))
            }
        } else {
            ContentUnavailableView("Select a Recording", systemImage: "text.bubble",
                                   description: Text("Pick a call to read its transcript and listen back. Select several with ⌘ or ⇧ to act on them together."))
        }
    }

    var body: some View {
        NavigationSplitView {
            if nav.showingSettings {
                SettingsSidebarView()
            } else {
                sidebar
            }
        } detail: {
            if nav.showingSettings {
                SettingsDetailView()
            } else {
                detailColumn
            }
        }
        .navigationTitle("Kaiku")
        .frame(minWidth: 820, minHeight: 520)
        .puiAccent(.kaiku)
        .onAppear {
            reload()
            if let sel = state.librarySelection { selection = [sel] }
            openRequestedChat()
        }
        .onChange(of: state.chatRequested) { _, _ in openRequestedChat() }
        .onChange(of: state.libraryVersion) { _, _ in reload() }
        .onChange(of: search) { _, v in if smartSearch { state.semantic.search(v) } }
        .onChange(of: smartSearchOn) { _, on in if !on { smartSearch = false } }
        .onChange(of: smartSearch) { _, on in
            guard on else { return }
            state.semantic.activate()
            state.semantic.search(search)
        }
        .onChange(of: state.librarySelection) { _, v in
            if let v, selection != [v] { selection = [v] }
        }
        .onChange(of: selection) { _, v in
            if v.count == 1, let only = v.first, state.librarySelection != only { state.librarySelection = only }
        }
        // A chat citation: show its call, even when the filters hide it.
        .onChange(of: state.librarySeek) { _, v in
            guard let v else { return }
            mode = .call
            if !filtered.contains(where: { $0.id == v.key }) {
                search = ""
                tagFilter = nil
                sourceFilter = nil
            }
            if selection != [v.key] { selection = [v.key] }
        }
        .confirmationDialog(deleteCallTargets.count == 1 ? "Move this call to the Trash?" : "Move \(deleteCallTargets.count) calls to the Trash?",
                            isPresented: isPresent($deleteCallTargets)) {
            Button(deleteCallTargets.count == 1 ? "Move to Trash" : "Move \(deleteCallTargets.count) Calls to Trash", role: .destructive) {
                let targets = deleteCallTargets
                perform { for f in targets { try state.trashCall(f) } }
                selection.subtract(targets.map(\.key))
            }
        } message: {
            Text("Each call folder, with audio and transcript, goes to the Trash. You can put it back from there.")
        }
        .confirmationDialog(deleteAudioTargets.count == 1 ? "Delete the audio of this call?" : "Delete the audio of \(deleteAudioTargets.count) calls?",
                            isPresented: isPresent($deleteAudioTargets)) {
            Button("Move Audio to Trash", role: .destructive) {
                let targets = deleteAudioTargets
                perform { for f in targets { try state.trashAudio(f) } }
            }
        } message: {
            Text("Transcripts stay. You won't be able to play these calls or transcribe them again.")
        }
        .sheet(item: $speakersTarget) { item in
            SpeakerRenameSheet(folder: item.folder, meta: item.meta)
        }
        .sheet(isPresented: isPresent($tagTargets)) {
            AddTagSheet(count: tagTargets.count, known: allTags) { tag in
                state.addTag(tag, to: tagTargets)
            }
        }
        .alert("Something went wrong", isPresented: isPresent($errorMessage)) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Chips to filter by one value (a tag or a source).
    private func filterBar(_ values: [String], selection: Binding<String?>, symbol: String? = nil) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
                        .help("Filter by source")
                }
                filterChip("All", selected: selection.wrappedValue == nil) { selection.wrappedValue = nil }
                ForEach(values, id: \.self) { value in
                    filterChip(value, selected: selection.wrappedValue == value) {
                        selection.wrappedValue = selection.wrappedValue == value ? nil : value
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.bar)
    }

    /// The switch for Smart search, with how far the indexing of the calls is.
    private var smartSearchBar: some View {
        HStack(spacing: 8) {
            filterChip("Smart search", selected: smartSearch) { smartSearch.toggle() }
                .help("Find passages by meaning, not only by the words typed")
            if smartSearch { SmartSearchStatus(semantic: state.semantic) }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(selected ? AnyShapeStyle(AppAccent.kaiku.color.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.7)), in: Capsule())
                .foregroundStyle(selected ? AnyShapeStyle(AppAccent.kaiku.color) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func contextMenu(for selected: [LibraryItem]) -> some View {
        let folders = selected.map(\.folder)
        let anyBusy = selected.contains { state.isBusy($0.folder) }
        if selected.count == 1, let item = selected.first {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder.url]) }
            Button("Copy Transcript") { copy(item.folder) }.disabled(!item.folder.hasTranscript)
            Divider()
        }
        if !selected.isEmpty {
            BulkActions(items: selected, request: requestAction, error: { errorMessage = $0 })
            Divider()
            Button("Move Audio to Trash…") { requestAction(.deleteAudio(folders)) }
                .disabled(anyBusy || !selected.contains { $0.meta.audioDeleted != true && !$0.folder.allAudioURLs.isEmpty })
            Button(selected.count == 1 ? "Move Call to Trash…" : "Move \(selected.count) Calls to Trash…") {
                requestAction(.deleteCalls(folders))
            }
            .disabled(anyBusy)
        }
    }

    private func requestAction(_ action: PendingAction) {
        switch action {
        case .deleteCalls(let f): deleteCallTargets = f
        case .deleteAudio(let f): deleteAudioTargets = f.filter { !$0.allAudioURLs.isEmpty }
        case .renameSpeakers(let f, let m): speakersTarget = LibraryItem(folder: f, meta: m, transcript: nil)
        case .addTag(let f): tagTargets = f
        case .chat(let f):
            let keys = Set(f.map(\.key))
            state.chat.start(with: items.filter { keys.contains($0.id) && $0.folder.hasTranscript }.map { ChatCall($0) })
            mode = .chat
        }
    }

    private func openRequestedChat() {
        guard state.chatRequested else { return }
        state.chatRequested = false
        mode = .chat
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    private func isPresent<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }

    private func isPresent(_ binding: Binding<[RecordingFolder]>) -> Binding<Bool> {
        Binding(get: { !binding.wrappedValue.isEmpty }, set: { if !$0 { binding.wrappedValue = [] } })
    }

    private func reload() {
        items = LibraryItem.loadAll()
        let ids = Set(items.map(\.id))
        selection = selection.intersection(ids)
        if let sel = state.librarySelection, !ids.contains(sel) {
            state.librarySelection = nil
        }
        // A filter whose tag or source is gone would hide every call with no way to clear it.
        if let tagFilter, !Tags.contains(allTags, tagFilter) { self.tagFilter = nil }
        if let sourceFilter, !Tags.contains(allSources, sourceFilter) { self.sourceFilter = nil }
    }
}

/// Actions that work on one or many calls: export, tag, transcribe, webhook.
/// Used in the context menu and the multi-selection toolbar.
struct BulkActions: View {
    @EnvironmentObject var state: AppState
    let items: [LibraryItem]
    let request: (PendingAction) -> Void
    let error: (String) -> Void

    var body: some View {
        let folders = items.map(\.folder)
        Menu("Export") {
            ForEach(ExportFormat.allCases) { format in
                Button(format.displayName + "…") {
                    let message = folders.count == 1
                        ? Exporter.export(folders[0], format: format)
                        : Exporter.export(folders, format: format)
                    if let message { error(message) }
                }
            }
        }
        .disabled(!items.contains { $0.folder.hasTranscript })
        Button("Add Tag…") { request(.addTag(folders)) }
        Button(items.count == 1 ? "Chat About This Call" : "Chat About These Calls") { request(.chat(folders)) }
            .disabled(!items.contains { $0.folder.hasTranscript })
        Menu("Transcribe Again") {
            ForEach(ProviderKind.available) { kind in
                Button(kind.displayName + (kind == AppSettings.provider ? " (default)" : "")) {
                    for f in folders where !state.isBusy(f) && f.loadMeta()?.audioDeleted != true && !f.audioURLs.isEmpty {
                        state.transcribe(folder: f, provider: kind)
                    }
                }
                .disabled(kind.readiness != .ready)
            }
        }
        .disabled(!items.contains { $0.meta.audioDeleted != true && !$0.folder.audioURLs.isEmpty && !state.isBusy($0.folder) })
        Button("Send Webhook") {
            Task { for f in folders where f.hasTranscript { await state.sendWebhook(f) } }
        }
        .disabled(AppSettings.webhookURL.isEmpty || !items.contains { $0.folder.hasTranscript })
    }
}

/// Detail pane when several calls are selected.
private struct MultiSelectionView: View {
    @EnvironmentObject var state: AppState
    let items: [LibraryItem]
    let request: (PendingAction) -> Void
    @State private var error: String?

    private var duration: Double { items.reduce(0) { $0 + $1.meta.durationSeconds } }
    private var bytes: Int64 { items.reduce(0) { $0 + $1.folder.totalBytes } }
    private var cost: Double { items.reduce(0) { $0 + ($1.meta.estimatedCostUSD ?? 0) } }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 40)).foregroundStyle(AppAccent.kaiku.color.gradient)
            Text("\(items.count) calls selected").font(.title2.weight(.bold))
            HStack(spacing: 18) {
                Label(TranscriptFormatter.timestamp(duration), systemImage: "clock")
                Label(Storage.format(bytes), systemImage: "internaldrive")
                if cost > 0 {
                    Label("~" + CostEstimator.format(cost), systemImage: "dollarsign.circle")
                        .help("Estimated transcription cost")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            ControlGroup {
                BulkActions(items: items, request: request, error: { error = $0 })
            }
            .fixedSize()
            HStack {
                Button("Move Audio to Trash…") { request(.deleteAudio(items.map(\.folder))) }
                Button("Move \(items.count) Calls to Trash…", role: .destructive) { request(.deleteCalls(items.map(\.folder))) }
            }
            .disabled(items.contains { state.isBusy($0.folder) })
            if let error {
                StatusDot(kind: .error, text: error).frame(maxWidth: 420)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Asks for one tag to add to the selected calls.
private struct AddTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let known: [String]
    let add: (String) -> Void
    @State private var tags: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Tag").font(.headline)
            Text(count == 1 ? "The tag is added to this call." : "The tags are added to all \(count) calls.")
                .font(.callout).foregroundStyle(.secondary)
            TagField(tags: $tags, known: known, placeholder: "Tag name")
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    tags.forEach(add)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle(height: PUI.Control.regular, fullWidth: false))
                .disabled(tags.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

func copy(_ folder: RecordingFolder) {
    guard let t = try? String(contentsOf: folder.transcriptURL, encoding: .utf8) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(t, forType: .string)
}

/// How far the indexing of the calls is, or why Smart search can't work.
private struct SmartSearchStatus: View {
    @ObservedObject var semantic: SemanticSearchModel

    var body: some View {
        if semantic.unavailable {
            Text("No language model on this Mac").font(.caption).foregroundStyle(.secondary)
        } else if let p = semantic.progress {
            Text("Indexing \(min(p.done + 1, p.total)) of \(p.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// The passages Smart search found, best first; a click opens the call at that moment.
private struct SmartResults: View {
    @ObservedObject var semantic: SemanticSearchModel
    let selected: Set<String>
    let open: (SemanticSearchModel.Hit) -> Void

    var body: some View {
        Group {
            if semantic.results.isEmpty {
                if semantic.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    ContentUnavailableView(semantic.progress == nil ? "No Matching Passages" : "Indexing Your Calls",
                                           systemImage: "sparkle.magnifyingglass",
                                           description: Text(semantic.progress == nil ? "Try describing it in other words."
                                                             : "Results appear as calls are indexed."))
                }
            } else {
                List(semantic.results) { hit in
                    Button { open(hit) } label: { SmartResultRow(hit: hit, selected: selected.contains(hit.folder.key)) }
                        .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private struct SmartResultRow: View {
    let hit: SemanticSearchModel.Hit
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.title).font(.body.weight(.medium)).lineLimit(1)
            Text(hit.passage.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 4) {
                Text(TranscriptFormatter.timestamp(hit.passage.start))
                    .monospacedDigit()
                    .foregroundStyle(AppAccent.kaiku.color)
                Text("·")
                Text(hit.date, format: .dateTime.day().month(.abbreviated))
                if let speaker = hit.passage.speaker {
                    Text("·")
                    Text(speaker).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AppAccent.kaiku.color.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryRow: View {
    let item: LibraryItem
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(status: busy && item.meta.status != .recording && item.meta.status != .paused ? .transcribing : item.meta.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.meta.title).font(.body.weight(.medium)).lineLimit(1)
                if let tags = item.meta.tags, !tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(tags.prefix(3), id: \.self) { TagCapsule(tag: $0, compact: true) }
                        if tags.count > 3 { Text("+\(tags.count - 3)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                HStack(spacing: 4) {
                    Text(item.meta.date, format: .dateTime.hour().minute())
                    if !Calendar.current.isDateInToday(item.meta.date) {
                        Text("·")
                        Text(item.meta.date, format: .dateTime.day().month(.abbreviated))
                    }
                    Spacer()
                    Text(TranscriptFormatter.timestamp(item.meta.durationSeconds))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

private struct RecordingDetail: View {
    @EnvironmentObject var state: AppState
    let item: LibraryItem
    let search: String
    let knownTags: [String]
    let request: (PendingAction) -> Void

    enum Tab: String { case transcript, summary }

    @State private var title = ""
    @State private var tags: [String] = []
    @State private var tab: Tab = .transcript
    @State private var summarizing = false
    @State private var summaryError: String?
    @State private var exportError: String?
    @State private var bytes: Int64 = 0
    @State private var editingTitle = false
    @State private var source = ""
    @State private var editingSource = false
    @FocusState private var titleFocused: Bool
    @State private var showErrorDetails = false
    @State private var webhookStatus: (ok: Bool, text: String)?
    @State private var sendingWebhook = false
    @State private var lines: [PlaybackLine] = []
    @StateObject private var holder = PlayerHolder()
    @AppStorage(Keys.readingTextSize) private var textSize = ReadingSize.standard

    private var player: AudioPlayerModel { holder.player }

    private var busy: Bool { state.isBusy(item.folder) }
    private var cancelled: Bool { item.meta.error == TranscriptionJob.cancelledMessage }
    private var hasAudio: Bool { item.meta.audioDeleted != true && !item.folder.audioURLs.isEmpty }
    private var blocks: [TranscriptBlock] { item.transcript.map(TranscriptFormatter.parseBlocks) ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                banners
                if hasAudio {
                    PlayerCard(player: player, bookmarks: bookmarks)
                } else if item.meta.audioDeleted == true {
                    Label("Audio deleted. The transcript is kept.", systemImage: "speaker.slash")
                        .font(.callout).foregroundStyle(.secondary)
                }
                actionRow
                if !bookmarks.isEmpty {
                    BookmarksSection(folder: item.folder, bookmarks: bookmarks, canSeek: hasAudio) { t in
                        player.seek(to: t, play: true)
                    }
                }
                if item.folder.hasSummary || AppSettings.summaryEnabled || tab == .summary {
                    Picker("Show", selection: $tab) {
                        Text("Transcript").tag(Tab.transcript)
                        Text("Summary").tag(Tab.summary)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                if tab == .summary {
                    summary
                } else {
                    transcript
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar { toolbar }
        .onAppear {
            title = item.meta.title
            source = item.meta.source ?? ""
            tags = item.meta.tags ?? []
            bytes = item.folder.totalBytes
            if item.folder.hasSummary && (!item.folder.hasTranscript || LibraryView.preferSummaryTab) { tab = .summary }
            loadAudio()
            follow(state.librarySeek)
        }
        .onChange(of: state.librarySeek) { _, v in follow(v) }
        .onDisappear { player.pause() }
        // Re-transcribed calls and renamed speakers rewrite transcript.md.
        .onChange(of: item.transcript, initial: true) { _, _ in loadLines() }
        // The audio files appear when a call shown while recording is saved.
        .onChange(of: hasAudio) { _, has in
            bytes = item.folder.totalBytes
            if has { loadAudio() }
        }
        .onChange(of: tags) { _, v in
            if v != (item.meta.tags ?? []) { state.setTags(item.folder, v) }
        }
        // Changes made elsewhere (context menu, renames) while this call stays selected.
        .onChange(of: item.meta.tags) { _, v in if (v ?? []) != tags { tags = v ?? [] } }
        .onChange(of: item.meta.title) { _, v in if !editingTitle { title = v } }
        .onChange(of: item.meta.source) { _, v in if !editingSource { source = v ?? "" } }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var bookmarks: [Bookmark] { (item.meta.bookmarks ?? []).sorted { $0.time < $1.time } }

    /// The turns of transcript.md, with word times from segments.json when the provider gave them.
    private func loadLines() {
        let blocks = self.blocks
        if let raw = item.folder.loadSegments() {
            let timed = PlaybackTranscript.lines(from: TranscriptWriter.displaySegments(meta: item.meta, rawSegments: raw, merge: false))
            // transcript.md is written from the same segments: use them only while both agree.
            if timed.count == blocks.count {
                lines = timed
                return
            }
        }
        lines = PlaybackTranscript.lines(from: blocks)
    }

    /// Plays from the moment a chat citation asked for, when it is about this call.
    private func follow(_ request: LibrarySeek?) {
        guard let request, request.key == item.id else { return }
        state.librarySeek = nil
        tab = .transcript
        guard let time = request.time, hasAudio else { return }
        Task { await player.play(from: time) }
    }

    private func loadAudio() {
        guard hasAudio, let url = [item.folder.mixedURL, item.folder.micURL, item.folder.systemURL]
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        player.load(url)
    }

    /// Copy (labeled, always visible), Export and Summary.
    private var actionRow: some View {
        HStack(spacing: 8) {
            CopyTranscriptButton(folder: item.folder)
                .buttonStyle(.bordered)
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.displayName + "…") { exportError = Exporter.export(item.folder, format: format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(!item.folder.hasTranscript)
            Button { generateSummary() } label: {
                Label(item.folder.hasSummary ? "Regenerate Summary" : "Generate Summary", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.bordered)
            .disabled(!item.folder.hasTranscript || busy || summarizing)
            .help(AppSettings.summaryProvider.problem.map { "\($0) Check Settings > Transcription > Summary" }
                  ?? "Summarize with \(AppSettings.summaryProvider.displayName) (\(AppSettings.summaryModel(for: AppSettings.summaryProvider)))")
            if summarizing { ProgressView().controlSize(.small) }
            Spacer()
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var summary: some View {
        if let text = item.folder.summary {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(markdown: text, size: textSize)
                if let model = item.meta.summaryModel {
                    Text("Written by \(model). Check important details against the transcript.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if !item.folder.loadActionItems().isEmpty { ActionItemsSection(folder: item.folder) }
            }
            .textSelection(.enabled)
            // Same reading column as the transcript text.
            .frame(maxWidth: TranscriptStyle.column, alignment: .leading)
            .padding(.leading, TranscriptStyle.gutter)
            .frame(maxWidth: TranscriptStyle.column + 2 * TranscriptStyle.gutter, alignment: .leading)
            .frame(maxWidth: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Summary Yet", systemImage: "list.bullet.rectangle")
            } description: {
                Text(summaryError ?? "Summaries use your own API key and never run unless you turn them on or ask here.")
            } actions: {
                Button("Generate Summary") { generateSummary() }
                    .buttonStyle(PrimaryButtonStyle(height: PUI.Control.regular, fullWidth: false))
                    .disabled(!item.folder.hasTranscript || summarizing)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func generateSummary() {
        summarizing = true
        summaryError = nil
        tab = .summary
        Task {
            do { try await state.generateSummary(item.folder) } catch { summaryError = error.localizedDescription }
            summarizing = false
        }
    }

    // Header: editable title + metadata.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if editingTitle {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .onSubmit {
                            state.rename(item.folder, to: title)
                            editingTitle = false
                        }
                        .onExitCommand { title = item.meta.title; editingTitle = false }
                        .onAppear { titleFocused = true }
                } else {
                    HStack(spacing: 8) {
                        Text(title).textSelection(.enabled)
                        Button { editingTitle = true } label: {
                            Image(systemName: "pencil").font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("Rename")
                        .accessibilityLabel("Rename")
                    }
                    .onTapGesture(count: 2) { editingTitle = true }
                }
            }
            .font(.system(size: 24, weight: .bold))
            HStack(spacing: 14) {
                Label(item.meta.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(TranscriptFormatter.timestamp(item.meta.durationSeconds), systemImage: "clock")
                Label(languageText, systemImage: "globe")
                if let model = item.meta.model {
                    Label(model, systemImage: "cpu").lineLimit(1)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabelStyle())
            HStack(spacing: 14) {
                Label(Storage.format(bytes), systemImage: "internaldrive")
                    .help("Size of this call's folder")
                if let cost = item.meta.estimatedCostUSD {
                    Label("~" + CostEstimator.format(cost) + " est.", systemImage: "dollarsign.circle")
                        .help(costHelp)
                }
                if let event = item.meta.calendarEvent {
                    Label(event.calendar.map { "\($0) event" } ?? "Calendar event", systemImage: "calendar.badge.clock")
                        .help(([event.title] + event.attendeeNames).joined(separator: "\n"))
                }
                sourceField
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabelStyle())
            TagField(tags: $tags, known: knownTags, placeholder: "Add tag")
                .font(.callout)
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    /// Where the call came from; editable, it only relabels this recording.
    @ViewBuilder private var sourceField: some View {
        if editingSource {
            TextField("Source", text: $source, prompt: Text("Source"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit {
                    state.setSource(item.folder, source)
                    editingSource = false
                }
                .onExitCommand { source = item.meta.source ?? ""; editingSource = false }
        } else {
            Button { editingSource = true } label: {
                Label(source.isEmpty ? "No source" : source, systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.borderless)
            .help((item.meta.sourceApp.map { "Recorded from \($0). " } ?? "") + "Click to change the source.")
            .accessibilityLabel("Source: \(source.isEmpty ? "none" : source). Change")
        }
    }

    private var costHelp: String {
        let minutes = (item.meta.transcribedSeconds ?? item.meta.durationSeconds) / 60
        return String(format: "Estimate: %.1f minutes sent to the provider", minutes)
            + (item.meta.modelID.map { " (\($0))" } ?? "")
            + ". Based on list prices you can edit in Settings > Transcription."
    }

    private var languageText: String {
        if item.meta.language == "auto" {
            return item.meta.detectedLanguage.map { "Auto (\($0))" } ?? "Auto-detect"
        }
        return LanguagePicker.displayName(item.meta.language)
    }

    @ViewBuilder private var banners: some View {
        if busy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.isRecordingFolder(item.folder) ? (state.isPaused ? "Recording paused" : "Recording in progress")
                         : (state.stage(for: item.folder) ?? "").hasPrefix("Writing summary") ? "Summarizing"
                         : (state.stage(for: item.folder) ?? "").hasPrefix("Saving") ? "Saving audio" : "Transcribing")
                        .font(.callout.weight(.medium))
                    Text(state.stage(for: item.folder) ?? "The transcript will appear here when it's ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.canCancelTranscription(item.folder) {
                    Button("Cancel") { state.cancelTranscription(item.folder) }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.regular))
                        .help("Stop transcribing. No summary or webhook is sent, and the call can then be deleted.")
                }
            }
            .padding(PUI.Space.l).puiSurface(radius: PUI.Radius.group)
        } else if item.meta.status == .recovered {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.blue).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recovered after an interruption").font(.callout.weight(.medium))
                    Text("The app quit during this call. The audio up to that moment is saved.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Transcribe") { state.transcribe(folder: item.folder, provider: AppSettings.provider) }
                    .buttonStyle(PrimaryButtonStyle(height: PUI.Control.regular, fullWidth: false))
                    .disabled(!hasAudio)
            }
            .padding(PUI.Space.l).puiSurface(radius: PUI.Radius.group)
        } else if item.meta.status == .error {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cancelled ? "Transcription cancelled" : "Transcription didn't finish").font(.callout.weight(.medium))
                        Text(cancelled ? "Your audio is safe. Transcribe it again or delete the call." : "Your audio is safe. Fix the problem and try again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !cancelled {
                        Button(showErrorDetails ? "Hide Details" : "Show Details") {
                            showErrorDetails.toggle()
                        }
                    }
                    Button("Try Again") { state.transcribe(folder: item.folder, provider: AppSettings.provider) }
                        .buttonStyle(PrimaryButtonStyle(height: PUI.Control.regular, fullWidth: false))
                        .disabled(!hasAudio)
                }
                if showErrorDetails, !cancelled, let err = item.meta.error {
                    Text(err).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(PUI.Space.l).puiSurface(radius: PUI.Radius.group)
        }
        if let webhookStatus {
            StatusDot(kind: webhookStatus.ok ? .ok : .error, text: webhookStatus.text)
        }
    }

    @ViewBuilder private var transcript: some View {
        if blocks.isEmpty {
            if !busy && item.meta.status != .error {
                ContentUnavailableView("No Transcript Yet", systemImage: "text.bubble",
                                       description: Text("Transcribe this call from the toolbar."))
                    .frame(maxWidth: .infinity)
            }
        } else {
            TranscriptLinesView(lines: lines, player: player, search: search, canSeek: hasAudio, textSize: textSize)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            TextSizeControl(size: $textSize)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { copy(item.folder) } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }
                .help("Copy transcript")
                .disabled(!item.folder.hasTranscript)
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.folder.url]) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show in Finder")
            Menu {
                ForEach(ProviderKind.available) { kind in
                    Button {
                        state.transcribe(folder: item.folder, provider: kind)
                    } label: {
                        Text(kind.displayName + (kind == AppSettings.provider ? " (default)" : ""))
                    }
                    .disabled(kind.readiness != .ready)
                }
            } label: {
                Label("Transcribe Again", systemImage: "arrow.clockwise")
            }
            .help("Transcribe again")
            .disabled(!hasAudio || busy)
            Button { request(.renameSpeakers(item.folder, item.meta)) } label: {
                Label("Rename Speakers", systemImage: "person.2")
            }
            .help("Rename speakers")
            .disabled(item.folder.loadSegments() == nil || busy)
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.displayName + "…") { exportError = Exporter.export(item.folder, format: format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export transcript")
            .disabled(!item.folder.hasTranscript)
            Button { resendWebhook() } label: { Label("Send Webhook", systemImage: "paperplane") }
                .help("Send webhook again")
                .disabled(!item.folder.hasTranscript || sendingWebhook || AppSettings.webhookURL.isEmpty)
            Menu {
                Button("Move Audio to Trash…") { request(.deleteAudio([item.folder])) }
                    .disabled(item.folder.allAudioURLs.isEmpty || busy)
                Button("Move Call to Trash…", role: .destructive) { request(.deleteCalls([item.folder])) }
                    .disabled(busy)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete")
        }
    }

    private func resendWebhook() {
        sendingWebhook = true
        Task {
            let status: (Bool, String)
            do {
                let r = try await Webhook.send(folder: item.folder)
                status = (true, "Webhook sent (HTTP \(r.statusCode))")
            } catch {
                status = (false, error.localizedDescription)
            }
            webhookStatus = status
            sendingWebhook = false
        }
    }
}

/// "A ••••• A": steps the reading text size down or up, also with ⌘− and ⌘+; ⌘0 goes back to the default.
private struct TextSizeControl: View {
    @Binding var size: Double

    var body: some View {
        HStack(spacing: 7) {
            Button { size = ReadingSize.smaller(than: size) } label: {
                Text("A").font(.system(size: 10, weight: .semibold))
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(size <= ReadingSize.steps[0])
            .help("Smaller text (⌘−)")
            .accessibilityLabel("Smaller text")
            HStack(spacing: 3) {
                ForEach(ReadingSize.steps, id: \.self) { step in
                    let on = abs(step - size) < 0.01
                    Circle()
                        .fill(on ? AnyShapeStyle(AppAccent.kaiku.color) : AnyShapeStyle(.quaternary))
                        .frame(width: on ? 8 : 6, height: on ? 8 : 6)
                        .frame(width: 8, height: 8)
                        .contentShape(Rectangle())
                        .onTapGesture { size = step }
                }
            }
            .accessibilityHidden(true)
            Button { size = ReadingSize.larger(than: size) } label: {
                Text("A").font(.system(size: 15, weight: .semibold))
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(size >= ReadingSize.steps[ReadingSize.steps.count - 1])
            .help("Larger text (⌘+)")
            .accessibilityLabel("Larger text")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .background {
            // ⌘= is ⌘+ without Shift on most layouts; ⌘0 restores the default size.
            Group {
                Button("") { size = ReadingSize.larger(than: size) }.keyboardShortcut("=", modifiers: .command)
                Button("") { size = ReadingSize.standard }.keyboardShortcut("0", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .help("Text size")
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The speaker turns, set as a reading column. While the call plays, the word being said is
/// highlighted (or the phrase, when the provider gave no word times); double-click one to play from there.
private struct TranscriptLinesView: View {
    let lines: [PlaybackLine]
    let player: AudioPlayerModel
    let search: String
    let canSeek: Bool
    let textSize: Double
    @State private var position: PlaybackTranscript.Position?

    var body: some View {
        let colors = Brand.speakerColors(lines.map(\.speaker))
        LazyVStack(alignment: .leading, spacing: 26) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let active = position?.line == index
                TranscriptLineView(line: line, color: colors[line.speaker] ?? .secondary, search: search, canSeek: canSeek,
                                   textSize: textSize, active: active, activeSpan: active ? position?.span : nil, seek: seek)
                    .equatable()
            }
        }
        // Timestamps sit in a gutter left of the column; with room to spare, the column is centered.
        .frame(maxWidth: TranscriptStyle.column + 2 * TranscriptStyle.gutter, alignment: .leading)
        .frame(maxWidth: .infinity)
        // Only the position is kept here, so a time update redraws the turns whose highlight changed.
        .onReceive(player.$time) { follow($0) }
        .onChange(of: lines) { _, _ in follow(player.time) }
    }

    private func seek(_ time: Double) {
        player.seek(to: time, play: true)
    }

    private func follow(_ time: Double) {
        let p = time > 0 ? PlaybackTranscript.position(at: time, in: lines) : nil
        if p != position { position = p }
    }
}

/// Type and measures of the transcript reading column.
enum TranscriptStyle {
    static let column: CGFloat = 680
    static let gutter: CGFloat = 84

    static func font(_ size: Double) -> NSFont { NSFont.systemFont(ofSize: size) }

    /// Extra space between lines for a line height of about 1.55 times the size.
    static func lineSpacing(_ size: Double) -> CGFloat {
        max(0, size * 1.55 - NSLayoutManager().defaultLineHeight(for: font(size)))
    }
}

private extension VerticalAlignment {
    /// The first line of a turn's text, so its timestamp lines up with it rather than with the speaker.
    enum TurnText: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.firstTextBaseline] }
    }
    static let turnText = VerticalAlignment(TurnText.self)
}

/// One speaker turn. Equatable so that it is redrawn only when its own highlight changes.
private struct TranscriptLineView: View, Equatable {
    let line: PlaybackLine
    let color: Color
    let search: String
    let canSeek: Bool
    let textSize: Double
    let active: Bool
    let activeSpan: Int?
    let seek: (Double) -> Void
    @State private var hover = false
    @State private var width: CGFloat = 0

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.line == b.line && a.color == b.color && a.search == b.search && a.canSeek == b.canSeek
            && a.textSize == b.textSize && a.active == b.active && a.activeSpan == b.activeSpan
    }

    var body: some View {
        HStack(alignment: .turnText, spacing: 0) {
            Button { seek(line.start) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 7)).opacity(hover && canSeek ? 1 : 0)
                    Text(TranscriptFormatter.timestamp(line.start))
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle((hover && canSeek) || active ? AnyShapeStyle(AppAccent.kaiku.color) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!canSeek)
            .help(canSeek ? "Play from here" : "")
            .accessibilityLabel("Play from \(TranscriptFormatter.timestamp(line.start))")
            // Shown only on the turn under the pointer and the one playing.
            .opacity(hover || active ? 1 : 0)
            .frame(width: TranscriptStyle.gutter, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(line.speaker)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                }
                let shown = displayed
                Text(highlighted(shown))
                    .font(.system(size: textSize))
                    .lineSpacing(TranscriptStyle.lineSpacing(textSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.turnText) { $0[.firstTextBaseline] }
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { width = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in width = w }
                    })
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(hover && canSeek ? 0.045 : 0))
                            .padding(.horizontal, -12)
                            .padding(.vertical, -6)
                    )
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                        guard canSeek else { return }
                        seek(time(at: value.location, aligned: String(shown.characters) == line.text))
                    })
            }
            .frame(maxWidth: TranscriptStyle.column, alignment: .leading)
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(line.speaker): \(String(displayed.characters))", forType: .string)
            }
            Button("Play from Here") { seek(line.start) }
                .disabled(!canSeek)
        }
    }

    /// The text with its Markdown styles, as before.
    private var displayed: AttributedString {
        (try? AttributedString(markdown: line.text)) ?? AttributedString(line.text)
    }

    private func highlighted(_ shown: AttributedString) -> AttributedString {
        var text = shown
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let r = text[searchRange].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[r].backgroundColor = Color.yellow.opacity(0.45)
                searchRange = r.upperBound..<text.endIndex
            }
        }
        guard let i = activeSpan, line.spans.indices.contains(i) else { return text }
        let span = line.spans[i]
        let highlight = AppAccent.kaiku.color.opacity(span.isWord ? 0.3 : 0.15)
        // Span offsets count the characters of the transcript text: when Markdown changed
        // them, highlight the whole turn instead.
        let count = text.characters.count
        guard String(text.characters) == line.text, span.range.upperBound <= count else {
            text[text.startIndex..<text.endIndex].backgroundColor = highlight
            return text
        }
        let lower = text.characters.index(text.startIndex, offsetBy: span.range.lowerBound)
        let upper = text.characters.index(lower, offsetBy: span.range.count)
        text[lower..<upper].backgroundColor = highlight
        return text
    }

    /// Where to play from for a double-click at `point` in the text.
    private func time(at point: CGPoint, aligned: Bool) -> Double {
        guard aligned, let offset = TranscriptHitTest.characterOffset(at: point, in: line.text, width: width, size: textSize) else {
            return line.start
        }
        return line.seekTime(atCharacter: offset)
    }
}

/// Finds the character under a click in transcript text. SwiftUI doesn't expose how it laid
/// the text out, so it is laid out again with TextKit in the same font, spacing and width.
@MainActor
enum TranscriptHitTest {
    static func characterOffset(at point: CGPoint, in text: String, width: CGFloat, size: Double) -> Int? {
        guard width > 0, !text.isEmpty else { return nil }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = TranscriptStyle.lineSpacing(size)
        let storage = NSTextStorage(string: text, attributes: [.font: TranscriptStyle.font(size), .paragraphStyle: style])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let index = layout.characterIndexForGlyph(at: layout.glyphIndex(for: point, in: container))
        let ns = text as NSString
        guard index < ns.length, let range = Range(ns.rangeOfComposedCharacterSequence(at: index), in: text) else { return nil }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }
}

// MARK: - Player

/// Owns the player without observing it, so the call detail isn't redrawn on every time update.
@MainActor
private final class PlayerHolder: ObservableObject {
    let player = AudioPlayerModel()
}

@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1 { didSet { if isPlaying { player.rate = rate } } }
    var scrubbing = false

    private let player = AVPlayer()
    private var observer: Any?

    func load(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        // Often enough to follow word by word in the transcript; it only runs while playing.
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.scrubbing { self.time = t.seconds }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
                self.isPlaying = self.player.rate > 0
            }
        }
        Task {
            if let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite { duration = d }
        }
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        if duration > 0, time >= duration - 0.1 { seek(to: 0, play: false) }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double, play: Bool) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play { self.play() }
    }

    /// Plays from `seconds` once the audio just loaded is ready, waiting up to five seconds.
    func play(from seconds: Double) async {
        var waited = 0
        while player.currentItem?.status != .readyToPlay, waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        seek(to: seconds, play: true)
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }
}

private struct PlayerCard: View {
    @ObservedObject var player: AudioPlayerModel
    var bookmarks: [Bookmark] = []
    @State private var spaceMonitor: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(AppAccent.kaiku.color.gradient, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Text(TranscriptFormatter.timestamp(player.time))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.time }, set: { player.time = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                player.scrubbing = editing
                if !editing { player.seek(to: player.time, play: player.isPlaying) }
            }
            .controlSize(.small)
            .tint(AppAccent.kaiku.color)
            .accessibilityLabel("Position")
            .overlay(alignment: .bottom) {
                if !bookmarks.isEmpty && player.duration > 0 { markers.offset(y: 9) }
            }
            Text(TranscriptFormatter.timestamp(player.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            Menu {
                Picker("Speed", selection: $player.rate) {
                    Text("1×").tag(Float(1))
                    Text("1.5×").tag(Float(1.5))
                    Text("2×").tag(Float(2))
                }
                .pickerStyle(.inline)
            } label: {
                Text(player.rate == 1 ? "1×" : (player.rate == 2 ? "2×" : "1.5×"))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Playback speed")
        }
        .padding(PUI.Space.l).puiSurface(radius: PUI.Radius.group)
        .onAppear(perform: watchSpace)
        .onDisappear {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
        }
    }

    /// Space plays and pauses in the library window, except while typing in a text field.
    private func watchSpace() {
        guard spaceMonitor == nil else { return }
        let player = self.player
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard event.charactersIgnoringModifiers == " ",
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                      let window = event.window, window === WindowManager.shared.window(WindowManager.mainID),
                      !(window.firstResponder is NSText) else { return false }
                player.toggle()
                return true
            }
            return handled ? nil : event
        }
    }

    /// Bookmark ticks under the scrubber; click one to jump there.
    private var markers: some View {
        GeometryReader { geo in
            let inset: CGFloat = 7
            let width = max(1, geo.size.width - inset * 2)
            ForEach(bookmarks) { b in
                Button { player.seek(to: b.time, play: true) } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(AppAccent.kaiku.color)
                        .frame(width: 12, height: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(TranscriptFormatter.timestamp(b.time)) \(b.displayLabel)")
                .position(x: inset + width * CGFloat(min(max(b.time / player.duration, 0), 1)), y: 5)
            }
        }
        .frame(height: 10)
    }
}

/// Bookmarks of a saved call: click the time to play, edit or remove the label.
private struct BookmarksSection: View {
    @EnvironmentObject var state: AppState
    let folder: RecordingFolder
    let bookmarks: [Bookmark]
    let canSeek: Bool
    let seek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bookmarks").font(.headline)
            ForEach(bookmarks) { b in
                BookmarkRow(bookmark: b, canSeek: canSeek, seek: { seek(b.time) },
                            save: { state.updateBookmark(folder, id: b.id, label: $0) },
                            remove: { state.updateBookmark(folder, id: b.id, label: nil) })
            }
        }
        .padding(PUI.Space.l).puiSurface(radius: PUI.Radius.group)
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    let canSeek: Bool
    let seek: () -> Void
    let save: (String) -> Void
    let remove: () -> Void
    @State private var label = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(action: seek) {
                HStack(spacing: 4) {
                    Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(AppAccent.kaiku.color)
                    Text(TranscriptFormatter.timestamp(bookmark.time)).font(.callout.monospacedDigit())
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSeek)
            .help(canSeek ? "Play from here" : "")
            TextField("Bookmark", text: $label, prompt: Text("Add a label"))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { save(label) }
                .onChange(of: focused) { _, f in if !f && label != bookmark.label { save(label) } }
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove bookmark")
                .accessibilityLabel("Remove bookmark")
        }
        .onAppear { label = bookmark.label }
    }
}

/// Renders the small Markdown subset used by summaries: headings, bullets, inline styles.
struct MarkdownText: View {
    let markdown: String
    /// Body size in points; nil keeps the system body size.
    var size: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Spacer().frame(height: 2)
                } else if line.hasPrefix("#") {
                    Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                        .font(heading(main: line.hasPrefix("# ")))
                        .padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(String(line.dropFirst(2)))).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, raw.hasPrefix("  ") ? 16 : 0)
                } else {
                    Text(inline(line)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(size.map { .system(size: $0) } ?? .body)
        .lineSpacing(size.map { TranscriptStyle.lineSpacing($0) } ?? 2)
    }

    private func heading(main: Bool) -> Font {
        guard let size else { return main ? .title3.weight(.bold) : .headline }
        return .system(size: main ? size + 3 : size, weight: .bold)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

// MARK: - Rename speakers

/// Maps raw speaker labels (Me, Others, Speaker 1…) to display names.
struct SpeakerRenameSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let folder: RecordingFolder
    let meta: RecordingMeta

    @State private var labels: [String] = []
    @State private var names: [String: String] = [:]
    @State private var error: String?

    private var suggestions: [String] { meta.calendarEvent?.attendeeNames ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename Speakers").font(.headline)
                Text(suggestions.isEmpty
                     ? "Names replace the labels in this transcript. You can change them again any time."
                     : "Names replace the labels in this transcript. Pick attendees from the calendar event, or type any name.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                ForEach(labels, id: \.self) { label in
                    LabeledContent {
                        HStack(spacing: 4) {
                            TextField(label, text: Binding(get: { names[label] ?? "" }, set: { names[label] = $0 }),
                                      prompt: Text(label))
                                .labelsHidden()
                            if !suggestions.isEmpty {
                                Menu {
                                    ForEach(suggestions, id: \.self) { name in
                                        Button(name) { names[label] = name }
                                    }
                                } label: {
                                    Image(systemName: "person.crop.circle.badge.plus")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Pick an attendee from the calendar event")
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Brand.speakerColors(labels)[label] ?? .secondary).frame(width: 8, height: 8)
                            Text(label)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                StatusDot(kind: .error, text: error).padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try state.renameSpeakers(folder, names: names); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle(height: PUI.Control.regular, fullWidth: false))
            }
            .padding(20)
        }
        .frame(width: 420)
        .onAppear {
            labels = TranscriptWriter.speakers(in: folder.loadSegments() ?? [])
            names = meta.speakerNames ?? [:]
        }
    }
}
