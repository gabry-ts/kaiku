import KaikuCore
import Observation
import SwiftUI

/// Turns audio and video files into calls, one file at a time, and queues them for transcription.
@MainActor
@Observable
final class PhoneImporter {
    static let shared = PhoneImporter()

    /// What the import is doing, e.g. "Importing 2 of 5…"; nil when idle.
    private(set) var status: String?
    /// Files that could not be imported, with the reason.
    var problems: [String] = []

    private var queue: [URL] = []
    /// Files to remove from the share inbox once handled.
    private var consumed = Set<URL>()
    private var total = 0
    private var current = 0
    private var running = false

    /// Queues the files; the ones that are not audio or video are reported. `consume` removes each file from where it
    /// was handed over (the share inbox) once it has been handled.
    func importFiles(_ urls: [URL], consume: Bool = false) {
        // The inbox is drained every time the app opens; files already being handled are skipped.
        let (supported, unsupported) = AudioImport.split(urls.filter { !consumed.contains($0) })
        for url in unsupported {
            problems.append("\"\(url.lastPathComponent)\": only audio and video files can be imported.")
            if consume { ImportInbox.remove(url) }
        }
        queue += supported
        if consume { consumed.formUnion(supported) }
        total += supported.count
        if !running, !queue.isEmpty {
            running = true
            Task { await run() }
        }
    }

    private func run() async {
        while !queue.isEmpty {
            let url = queue.removeFirst()
            current += 1
            status = AudioImport.progress(current: current, total: total)
            do {
                let folder = try await importFile(url)
                PhoneJobs.shared.enqueue(folder)
            } catch {
                problems.append("\"\(url.lastPathComponent)\": \(error.localizedDescription)")
            }
            if consumed.remove(url) != nil { ImportInbox.remove(url) }
        }
        status = nil
        total = 0
        current = 0
        running = false
        PhoneJobs.shared.onChange?()
    }

    /// Converts the file's audio into a new call folder, as its only track.
    private func importFile(_ url: URL) async throws -> RecordingFolder {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let work = try AudioTools.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let audio = work.appendingPathComponent(RecordingFolder.systemName)
        try await MediaAudio.extract(from: url, to: audio)
        let seconds = await Task.detached { AudioFiles.duration(audio) }.value ?? 0
        guard seconds > 0 else { throw ImportError(message: "The file has no audio.") }

        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        let title = AudioImport.title(for: url)
        let date = AudioImport.date(created: created)
        let folder = try RecordingFolder.create(base: PhoneSettings.baseFolder, date: date, title: title)
        do {
            try FileManager.default.moveItem(at: audio, to: folder.systemURL)
        } catch {
            // Only the empty folder just made is removed.
            try? FileManager.default.removeItem(at: folder.url)
            throw error
        }
        try folder.saveMeta(RecordingMeta(
            title: title, date: date, durationSeconds: seconds, language: PhoneSettings.language,
            status: .recovered, source: CallSource.imported))
        return folder
    }
}

/// A toolbar button that picks audio and video files to import.
struct ImportButton: View {
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: { Image(systemName: "square.and.arrow.down") }
            .accessibilityLabel("Import audio or video")
            .fileImporter(isPresented: $choosing, allowedContentTypes: AudioImport.contentTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { PhoneImporter.shared.importFiles(urls) }
            }
    }
}
