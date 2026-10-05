import SwiftUI
import KaikuCore

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @State private var query = ""
    @State private var pendingDelete: RecordingFolder?

    var body: some View {
        NavigationStack {
            let calls = store.calls(matching: query)
            List {
                ForEach(calls, id: \.folder.id) { entry in
                    NavigationLink(value: entry.folder) { CallRow(meta: entry.meta) }
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDelete = entry.folder }
                        }
                }
            }
            .overlay {
                if store.calls.isEmpty {
                    ContentUnavailableView("No calls yet", systemImage: "mic", description: Text("Recordings and imports appear here."))
                } else if calls.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: RecordingFolder.self) { CallDetailView(folder: $0) }
            .searchable(text: $query, prompt: "Search calls and transcripts")
            .refreshable { store.reload() }
            .confirmationDialog("Delete this call?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let folder = pendingDelete { store.delete(folder) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("The audio, transcript and summary are removed from this iPhone.")
            }
        }
        .onAppear { store.reload() }
    }
}

struct CallRow: View {
    let meta: RecordingMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meta.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                Text(meta.date.formatted(date: .abbreviated, time: .shortened))
                if meta.durationSeconds > 0 { Text("· " + duration(meta.durationSeconds)) }
                if let state = statusText { Text("· " + state).foregroundStyle(meta.status == .error ? Color.red : Color.accentColor) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let tags = meta.tags, !tags.isEmpty {
                Text(tags.map { "#" + $0 }.joined(separator: " ")).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String? {
        switch meta.status {
        case .done: return nil
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .transcribing: return "Transcribing"
        case .error: return "Failed"
        case .recovered: return "Not transcribed"
        }
    }
}

func duration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600, m = total % 3600 / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
