import SwiftUI
import KaikuCore

struct CallDetailView: View {
    let folder: RecordingFolder
    @Environment(LibraryStore.self) private var store
    @Environment(PhoneJobs.self) private var jobs
    @Environment(\.dismiss) private var dismiss
    @State private var meta: RecordingMeta?
    @State private var player: PlayerModel?
    @State private var editing: Edit?
    @State private var draft = ""
    @State private var sharing = false
    @State private var confirmDelete = false
    @State private var summarizing = false
    @State private var summaryError: String?

    private enum Edit: Identifiable {
        case title, tags
        var id: Self { self }
    }

    var body: some View {
        Group {
            if let meta {
                List {
                    Section {
                        LabeledContent("Date", value: meta.date.formatted(date: .abbreviated, time: .shortened))
                        if meta.durationSeconds > 0 { LabeledContent("Duration", value: duration(meta.durationSeconds)) }
                        if let source = meta.source { LabeledContent("Source", value: source) }
                        LabeledContent("Tags", value: (meta.tags ?? []).joined(separator: ", ").nilIfEmpty ?? "None")
                        if meta.status != .done {
                            LabeledContent("Status", value: jobs.status(for: folder) ?? statusText(meta))
                        }
                        if let error = meta.error, !jobs.isActive(folder) {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        if jobs.isActive(folder) {
                            Button("Cancel transcription", role: .destructive) { jobs.cancel(folder) }
                        } else if meta.status == .error || meta.status == .recovered || meta.status == .done {
                            Button(meta.status == .done ? "Transcribe again" : "Transcribe") { jobs.enqueue(folder) }
                                .disabled(folder.audioURLs.isEmpty)
                        }
                    }
                    if folder.hasTranscript {
                        Section("Summary") {
                            if let summary = folder.summary {
                                Text(Self.markdown(summary)).textSelection(.enabled)
                            }
                            if let message = summaryError ?? jobs.summaryErrors[folder.key] {
                                Text(message).font(.footnote).foregroundStyle(.red)
                            }
                            Button(summarizing ? "Writing summary…" : (folder.hasSummary ? "Write summary again" : "Write summary")) {
                                summarize()
                            }
                            .disabled(summarizing || jobs.isActive(folder))
                        }
                        Section {
                            NavigationLink("Transcript") { TranscriptView(folder: folder, meta: meta, player: player) }
                            NavigationLink("Ask about this call") {
                                ChatView(title: meta.title, calls: [CallEntry(folder: folder, meta: meta)])
                            }
                        }
                    }
                    if let bookmarks = meta.bookmarks, !bookmarks.isEmpty {
                        Section("Bookmarks") {
                            ForEach(bookmarks) { bookmark in
                                Button {
                                    player?.seek(to: bookmark.time, play: true)
                                } label: {
                                    HStack {
                                        Text(bookmark.displayLabel)
                                        Spacer()
                                        Text(duration(bookmark.time)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { if let player { PlayerBar(player: player) } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(meta?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename", systemImage: "pencil") { draft = meta?.title ?? ""; editing = .title }
                    Button("Edit tags", systemImage: "tag") { draft = (meta?.tags ?? []).joined(separator: ", "); editing = .tags }
                    Button("Share", systemImage: "square.and.arrow.up") { sharing = true }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(editing == .title ? "Rename" : "Tags", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(editing == .title ? "Title" : "Tags, separated by commas", text: $draft)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this call?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player?.stop()
                store.delete(folder)
                dismiss()
            }
        }
        .sheet(isPresented: $sharing) { if let meta { ExportSheet(folder: folder, meta: meta) } }
        .onAppear { load() }
        .onChange(of: jobs.current?.key) { load() }
        .onChange(of: jobs.queue.count) { load() }
        .onDisappear { player?.stop() }
    }

    private func load() {
        meta = folder.loadMeta()
        if player == nil { player = PlayerModel(folder: folder) }
    }

    private func summarize() {
        summarizing = true
        summaryError = nil
        Task {
            do {
                try await PhoneSummary.run(folder: folder)
            } catch {
                summaryError = error.localizedDescription
            }
            summarizing = false
            load()
        }
    }

    private func save() {
        switch editing {
        case .title: store.rename(folder, to: draft)
        case .tags: store.setTags(folder, draft.components(separatedBy: ","))
        case nil: break
        }
        editing = nil
        meta = folder.loadMeta()
    }

    private func statusText(_ meta: RecordingMeta) -> String {
        switch meta.status {
        case .done: return "Done"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .transcribing: return "Transcribing"
        case .error: return "Failed"
        case .recovered: return "Not transcribed"
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
