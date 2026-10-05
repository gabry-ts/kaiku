import SwiftUI
import KaikuCore

/// Share the transcript in any format, the summary and the audio.
struct ExportSheet: View {
    let folder: RecordingFolder
    let meta: RecordingMeta
    @Environment(\.dismiss) private var dismiss
    @State private var files: [(title: String, url: URL)] = []

    var body: some View {
        NavigationStack {
            List {
                if !files.isEmpty {
                    ForEach(files, id: \.url) { file in
                        ShareLink(item: file.url) { Label(file.title, systemImage: "square.and.arrow.up") }
                    }
                } else {
                    Text("Nothing to share yet.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { files = prepare() }
        }
        .presentationDetents([.medium])
    }

    /// Writes the exports to a temporary folder, so each file is shared under a readable name.
    private func prepare() -> [(title: String, url: URL)] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [(title: String, url: URL)] = []

        if folder.hasTranscript, let raw = folder.loadSegments() {
            let markdown = try? String(contentsOf: folder.transcriptURL, encoding: .utf8)
            let doc = ExportDocument(
                title: meta.title, date: meta.date, durationSeconds: meta.durationSeconds,
                provider: meta.model ?? meta.provider ?? "unknown", language: TranscriptWriter.languageLabel(meta),
                segments: TranscriptWriter.displaySegments(meta: meta, rawSegments: raw, merge: false),
                bookmarks: meta.bookmarks ?? [], markdown: markdown, tags: meta.tags ?? [])
            for format in ExportFormat.allCases {
                let url = dir.appendingPathComponent(ExportFormatter.fileName(title: meta.title, date: meta.date, format: format))
                if (try? ExportFormatter.data(doc, format: format).write(to: url)) != nil {
                    out.append(("Transcript, \(format.displayName)", url))
                }
            }
        }
        if let summary = folder.summary {
            let url = dir.appendingPathComponent(
                ExportFormatter.fileName(title: meta.title + " summary", date: meta.date, format: .md))
            if (try? summary.write(to: url, atomically: true, encoding: .utf8)) != nil { out.append(("Summary, Markdown", url)) }
        }
        for audio in folder.audioURLs { out.append(("Audio, \(audio.lastPathComponent)", audio)) }
        return out
    }
}
