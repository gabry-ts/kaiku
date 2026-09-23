import AVFoundation
import SwiftUI
import McRofoneCore

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
}

struct LibraryView: View {
    /// Snapshot rendering opens calls that have a summary on the Summary tab.
    static var preferSummaryTab = false

    @EnvironmentObject var state: AppState
    @State private var items: [LibraryItem] = []
    @State private var search = ""
    @State private var tagFilter: String?
    @State private var selection: Set<String> = []
    @State private var deleteCallTargets: [RecordingFolder] = []
    @State private var deleteAudioTargets: [RecordingFolder] = []
    @State private var tagTargets: [RecordingFolder] = []
    @State private var speakersTarget: LibraryItem?
    @State private var errorMessage: String?

    private var allTags: [String] {
        Tags.byRecency(items.map { ($0.meta.date, $0.meta.tags ?? []) })
    }

    private var filtered: [LibraryItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            let tags = item.meta.tags ?? []
            if let tagFilter, !Tags.contains(tags, tagFilter) { return false }
            guard !q.isEmpty else { return true }
            return item.meta.title.localizedCaseInsensitiveContains(q)
                || tags.contains { $0.localizedCaseInsensitiveContains(q) }
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

    var body: some View {
        NavigationSplitView {
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
                if !allTags.isEmpty { tagFilterBar }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search calls, tags and transcripts")
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
            .overlay {
                if items.isEmpty {
                    Text("No recordings").foregroundStyle(.tertiary)
                } else if filtered.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("No Calls Tagged \(tagFilter ?? "")", systemImage: "tag")
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
        } detail: {
            if selectedItems.count > 1 {
                MultiSelectionView(items: selectedItems, request: requestAction)
            } else if let item = selectedItems.first {
                RecordingDetail(item: item, search: search, knownTags: allTags, request: requestAction)
                    .id(item.id)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings Yet", systemImage: "waveform.and.mic")
                } description: {
                    Text(HotKeyPreset.current == .off
                         ? "Start one from the menu bar. Calls are saved in \(AppSettings.baseFolderDisplayPath)."
                         : "Start one from the menu bar or press \(HotKeyPreset.current.display) from any app.")
                } actions: {
                    Button("Start Recording") { state.requestStart() }
                        .buttonStyle(.primary)
                }
            } else {
                ContentUnavailableView("Select a Recording", systemImage: "text.bubble",
                                       description: Text("Pick a call to read its transcript and listen back. Select several with ⌘ or ⇧ to act on them together."))
            }
        }
        .navigationTitle("Recordings")
        .frame(minWidth: 820, minHeight: 520)
        .onAppear {
            reload()
            if let sel = state.librarySelection { selection = [sel] }
        }
        .onChange(of: state.libraryVersion) { _, _ in reload() }
        .onChange(of: state.librarySelection) { _, v in
            if let v, selection != [v] { selection = [v] }
        }
        .onChange(of: selection) { _, v in
            if v.count == 1, let only = v.first, state.librarySelection != only { state.librarySelection = only }
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

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                filterChip("All", selected: tagFilter == nil) { tagFilter = nil }
                ForEach(allTags, id: \.self) { tag in
                    filterChip(tag, selected: tagFilter == tag) { tagFilter = tagFilter == tag ? nil : tag }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(selected ? AnyShapeStyle(Brand.accent.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.7)), in: Capsule())
                .foregroundStyle(selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.primary))
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
        }
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
        Menu("Transcribe Again") {
            ForEach(ProviderKind.allCases) { kind in
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
                .font(.system(size: 40)).foregroundStyle(Brand.accent.gradient)
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
                .buttonStyle(.primary)
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
    @FocusState private var titleFocused: Bool
    @State private var showErrorDetails = false
    @State private var webhookStatus: (ok: Bool, text: String)?
    @State private var sendingWebhook = false
    @StateObject private var player = AudioPlayerModel()

    private var busy: Bool { state.isBusy(item.folder) }
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
            tags = item.meta.tags ?? []
            bytes = item.folder.totalBytes
            if item.folder.hasSummary && (!item.folder.hasTranscript || LibraryView.preferSummaryTab) { tab = .summary }
            if hasAudio, let url = [item.folder.mixedURL, item.folder.micURL, item.folder.systemURL]
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                player.load(url)
            }
        }
        .onDisappear { player.pause() }
        .onChange(of: tags) { _, v in
            if v != (item.meta.tags ?? []) { state.setTags(item.folder, v) }
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var bookmarks: [Bookmark] { (item.meta.bookmarks ?? []).sorted { $0.time < $1.time } }

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
            .help(AppSettings.summaryProvider.apiKey == nil
                  ? "Add an API key in Settings > Transcription > Summary"
                  : "Summarize with \(AppSettings.summaryProvider.displayName) (\(AppSettings.summaryModel(for: AppSettings.summaryProvider)))")
            if summarizing { ProgressView().controlSize(.small) }
            Spacer()
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var summary: some View {
        if let text = item.folder.summary {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(markdown: text)
                if let model = item.meta.summaryModel {
                    Text("Written by \(model). Check important details against the transcript.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .textSelection(.enabled)
        } else {
            ContentUnavailableView {
                Label("No Summary Yet", systemImage: "list.bullet.rectangle")
            } description: {
                Text(summaryError ?? "Summaries use your own API key and never run unless you turn them on or ask here.")
            } actions: {
                Button("Generate Summary") { generateSummary() }
                    .buttonStyle(.primary)
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
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabelStyle())
            TagField(tags: $tags, known: knownTags, placeholder: "Add tag")
                .font(.callout)
                .frame(maxWidth: 520, alignment: .leading)
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
            }
            .card()
        } else if item.meta.status == .recovered {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.blue).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recovered after an interruption").font(.callout.weight(.medium))
                    Text("The app quit during this call. The audio up to that moment is saved.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Transcribe") { state.transcribe(folder: item.folder, provider: AppSettings.provider) }
                    .buttonStyle(.primary)
                    .disabled(!hasAudio)
            }
            .card()
        } else if item.meta.status == .error {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Transcription didn't finish").font(.callout.weight(.medium))
                        Text("Your audio is safe. Fix the problem and try again.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(showErrorDetails ? "Hide Details" : "Show Details") {
                        withAnimation(.snappy) { showErrorDetails.toggle() }
                    }
                    Button("Try Again") { state.transcribe(folder: item.folder, provider: AppSettings.provider) }
                        .buttonStyle(.primary)
                        .disabled(!hasAudio)
                }
                if showErrorDetails, let err = item.meta.error {
                    Text(err).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .transition(.opacity)
                }
            }
            .card()
        }
        if let webhookStatus {
            StatusDot(kind: webhookStatus.ok ? .ok : .error, text: webhookStatus.text)
                .transition(.opacity)
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
            let colors = Brand.speakerColors(blocks.map(\.speaker))
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    TranscriptBlockView(block: block, color: colors[block.speaker] ?? .secondary,
                                        search: search, canSeek: hasAudio) {
                        player.seek(to: block.start, play: true)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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
                ForEach(ProviderKind.allCases) { kind in
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
            withAnimation { webhookStatus = status }
            sendingWebhook = false
        }
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

private struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let color: Color
    let search: String
    let canSeek: Bool
    let seek: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button(action: seek) {
                HStack(spacing: 3) {
                    Text(TranscriptFormatter.timestamp(block.start))
                    Image(systemName: "play.fill").font(.system(size: 7)).opacity(hover && canSeek ? 1 : 0)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(hover && canSeek ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .disabled(!canSeek)
            .help(canSeek ? "Play from here" : "")
            .accessibilityLabel("Play from \(TranscriptFormatter.timestamp(block.start))")
            .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(block.speaker)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                Text(highlighted)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var highlighted: AttributedString {
        var text = (try? AttributedString(markdown: block.text)) ?? AttributedString(block.text)
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return text }
        var searchRange = text.startIndex..<text.endIndex
        while let r = text[searchRange].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[r].backgroundColor = Color.yellow.opacity(0.45)
            searchRange = r.upperBound..<text.endIndex
        }
        return text
    }
}

// MARK: - Player

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
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
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

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }
}

private struct PlayerCard: View {
    @ObservedObject var player: AudioPlayerModel
    var bookmarks: [Bookmark] = []

    var body: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Brand.accent.gradient, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Text(TranscriptFormatter.timestamp(player.time))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.time }, set: { player.time = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                player.scrubbing = editing
                if !editing { player.seek(to: player.time, play: player.isPlaying) }
            }
            .controlSize(.small)
            .tint(Brand.accent)
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
        .card()
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
                        .foregroundStyle(Brand.accent)
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
        .card()
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
                    Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Brand.accent)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Spacer().frame(height: 2)
                } else if line.hasPrefix("#") {
                    Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                        .font(line.hasPrefix("# ") ? .title3.weight(.bold) : .headline)
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
        .font(.body)
        .lineSpacing(2)
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
                .buttonStyle(.primary)
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
