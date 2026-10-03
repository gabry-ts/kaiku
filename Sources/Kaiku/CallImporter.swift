import AppKit
import AVFoundation
import KaikuCore

/// Turns audio and video files into calls and transcribes them, one file at a time.
@MainActor
final class CallImporter: ObservableObject {
    static let shared = CallImporter()

    /// What the import is doing, e.g. "Importing 2 of 5…"; nil when idle.
    @Published private(set) var status: String?

    private var queue: [URL] = []
    /// Files in the current batch, and the one being worked on (1-based).
    private var total = 0
    private var current = 0
    private var running = false

    /// Queues the files for import; files that are not audio or video are skipped with a notification.
    func importFiles(_ urls: [URL]) {
        let (supported, unsupported) = AudioImport.split(urls)
        for url in unsupported {
            notifySkipped(url, reason: "Only audio and video files can be imported.")
        }
        let new = supported.filter { url in !queue.contains { $0.standardizedFileURL == url.standardizedFileURL } }
        guard !new.isEmpty else { return }
        queue += new
        total += new.count
        Log.app.info("Queued \(new.count) file(s) for import")
        if !running {
            running = true
            Task { await run() }
        }
    }

    /// Shows the Open panel to choose files to import.
    func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioImport.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose audio or video files to transcribe."
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { CallImporter.shared.importFiles(urls) }
        }
    }

    private func run() async {
        let state = AppState.shared
        while !queue.isEmpty {
            let url = queue.removeFirst()
            current += 1
            status = AudioImport.progress(current: current, total: total)
            do {
                let folder = try await importFile(url)
                if current == 1 { state.openInLibrary(folder) }
                status = total > 1 ? "Transcribing \(current) of \(total)…" : nil
                state.transcribe(folder: folder, provider: AppSettings.provider)
                await state.waitForTranscription(folder)
            } catch {
                Log.app.error("Import failed for \(url.lastPathComponent, privacy: .public): \(error.diagnosticDescription, privacy: .public)")
                notifySkipped(url, reason: error.localizedDescription)
            }
        }
        status = nil
        total = 0
        current = 0
        running = false
    }

    /// Converts the file's audio into a new call folder, as its only track.
    private func importFile(_ url: URL) async throws -> RecordingFolder {
        let work = try AudioTools.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let audio = work.appendingPathComponent(RecordingFolder.systemName)
        try await MediaAudio.extract(from: url, to: audio)
        let duration = await Task.detached { AudioFiles.duration(audio) }.value ?? 0
        guard duration > 0 else { throw ImportError(message: "The file has no audio.") }

        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        let title = AudioImport.title(for: url)
        let date = AudioImport.date(created: created)
        let folder = try AppState.shared.makeFolder(date: date, title: title)
        do {
            try FileManager.default.moveItem(at: audio, to: folder.systemURL)
        } catch {
            // Only the empty folder just made is removed.
            try? FileManager.default.removeItem(at: folder.url)
            throw error
        }
        try folder.saveMeta(RecordingMeta(
            title: title, date: date, durationSeconds: duration, language: AppSettings.language,
            status: .transcribing, source: CallSource.imported))
        Log.app.info("Imported \(url.lastPathComponent, privacy: .public) into \(folder.url.lastPathComponent, privacy: .public)")
        return folder
    }

    private func notifySkipped(_ url: URL, reason: String) {
        Notifier.shared.post(.problem, title: "Couldn't import \"\(url.lastPathComponent)\"", body: reason, folderPath: nil)
    }
}

struct ImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Audio of any file AVFoundation can read, saved as AAC .m4a.
enum MediaAudio {
    static func extract(from source: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        do {
            guard !tracks.isEmpty else { throw ImportError(message: "The file has no audio track.") }
            try await export(asset, to: output)
        } catch {
            // Some audio formats open as plain audio files but not as assets.
            try? FileManager.default.removeItem(at: output)
            let converted = await Task.detached { try? AudioFiles.convertToM4A(source, output: output) }.value
            if converted != nil { return }
            try? FileManager.default.removeItem(at: output)
            throw tracks.isEmpty ? ImportError(message: "The file has no audio track Kaiku can read.") : error
        }
    }

    private static func export(_ asset: AVURLAsset, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError(message: "The audio can't be converted.")
        }
        if #available(macOS 15, *) {
            try await session.export(to: output, as: .m4a)
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? ImportError(message: "The audio can't be converted.")
            }
        }
    }
}
