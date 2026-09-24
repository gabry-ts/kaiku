import AppKit
import KaikuCore
import UniformTypeIdentifiers

/// Exports transcripts to Markdown, text, subtitles or Word.
@MainActor
enum Exporter {
    static func document(for folder: RecordingFolder) -> ExportDocument? {
        guard let meta = folder.loadMeta() else { return nil }
        let markdown = try? String(contentsOf: folder.transcriptURL, encoding: .utf8)
        var segments: [Segment]
        if let raw = folder.loadSegments() {
            segments = TranscriptWriter.displaySegments(meta: meta, rawSegments: raw, merge: false)
        } else if let markdown {
            // Older calls without segments.json: rebuild from the transcript turns.
            let blocks = TranscriptFormatter.parseBlocks(markdown)
            segments = blocks.enumerated().map { i, b in
                let end = i + 1 < blocks.count ? blocks[i + 1].start : max(b.start + 5, meta.durationSeconds)
                return Segment(start: b.start, end: end, speaker: b.speaker, text: b.text)
            }
        } else {
            return nil
        }
        segments.sort { $0.start < $1.start }
        return ExportDocument(
            title: meta.title, date: meta.date, durationSeconds: meta.durationSeconds,
            provider: meta.model ?? meta.provider ?? "unknown", language: TranscriptWriter.languageLabel(meta),
            segments: segments, bookmarks: meta.bookmarks ?? [], markdown: markdown, tags: meta.tags ?? [])
    }

    private static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Save panel for one call. Returns an error message, or nil.
    static func export(_ folder: RecordingFolder, format: ExportFormat) -> String? {
        guard let doc = document(for: folder) else { return "This call has no transcript to export." }
        let panel = NSSavePanel()
        panel.directoryURL = downloads
        panel.nameFieldStringValue = ExportFormatter.fileName(title: doc.title, date: doc.date, format: format)
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try ExportFormatter.data(doc, format: format).write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Folder picker, then one file per call. Returns a summary message.
    static func export(_ folders: [RecordingFolder], format: ExportFormat) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloads
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for \(folders.count) \(format.displayName) files."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return nil }
        var skipped = 0
        var failed: [String] = []
        for folder in folders {
            guard let doc = document(for: folder) else { skipped += 1; continue }
            let url = unique(dir.appendingPathComponent(ExportFormatter.fileName(title: doc.title, date: doc.date, format: format)))
            do { try ExportFormatter.data(doc, format: format).write(to: url, options: .atomic) }
            catch { failed.append("\(doc.title): \(error.localizedDescription)") }
        }
        if failed.isEmpty && skipped == 0 {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
            return nil
        }
        var parts: [String] = []
        if skipped > 0 { parts.append("\(skipped) call\(skipped == 1 ? "" : "s") without a transcript were skipped.") }
        parts += failed
        return parts.joined(separator: "\n")
    }

    private static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }
}
