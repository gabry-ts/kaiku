import Foundation
import KaikuCore

/// Files an agent asked kaiku-mcp to transcribe. Each is transcribed in its own job folder
/// outside the library, with the provider and settings of the app; the server reads the
/// result there and removes the folder. Asked to save, the call moves into the library as
/// an import. Nothing shows in the menu while it works.
@MainActor
enum AgentTranscription {
    static func run(_ job: FileJob) {
        guard AppSettings.agentsAllowFiles else {
            Log.app.error("Ignored a file an agent asked to transcribe: turned off in Settings")
            return
        }
        guard let url = KaikuAgents.jobFolder(job.id) else { return }
        removeOldJobs()
        Log.app.info("An agent asked to transcribe \(URL(fileURLWithPath: job.path).lastPathComponent, privacy: .public)")
        Task { await transcribe(job, in: RecordingFolder(url: url)) }
    }

    private static func transcribe(_ job: FileJob, in folder: RecordingFolder) async {
        let source = URL(fileURLWithPath: job.path)
        let title = AudioImport.title(for: source)
        let language = job.language.map { AppSettings.normalizedLanguage($0) } ?? AppSettings.language
        var result = FileJobResult()
        do {
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try folder.saveMeta(RecordingMeta(title: title, date: Date(), durationSeconds: 0, language: language,
                                              status: .transcribing, source: CallSource.imported))
            guard job.path.hasPrefix("/"), FileManager.default.fileExists(atPath: job.path) else {
                throw ProviderError(message: "There is no file at \(job.path).")
            }
            guard AudioImport.isSupported(source) else {
                throw ProviderError(message: "Kaiku can't read \(source.lastPathComponent): not an audio or video file it knows.")
            }
            try await MediaAudio.extract(from: source, to: folder.systemURL)
            let audio = folder.systemURL
            let duration = await Task.detached { AudioFiles.duration(audio) }.value ?? 0
            guard duration > 0 else { throw ProviderError(message: "\(source.lastPathComponent) has no audio.") }
            folder.updateMeta { $0.durationSeconds = duration }
            try await TranscriptionJob.run(folder: folder, providerKind: AppSettings.provider)
            if job.summary {
                do { try await SummaryJob.run(folder: folder) } catch { result.summaryError = error.localizedDescription }
            }
            if job.save { result.savedFolder = try save(folder, title: title).url.path }
        } catch {
            result.error = error.diagnosticDescription
            folder.updateMeta { $0.status = .error; $0.error = error.diagnosticDescription }
        }
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: folder.url.appendingPathComponent(FileJobResult.fileName), options: .atomic)
        }
    }

    /// Moves everything but the result into a new call folder in the library.
    private static func save(_ job: RecordingFolder, title: String) throws -> RecordingFolder {
        let call = try AppState.shared.makeFolder(date: job.loadMeta()?.date ?? Date(), title: title)
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: job.url, includingPropertiesForKeys: nil) {
            try fm.moveItem(at: item, to: call.url.appendingPathComponent(item.lastPathComponent))
        }
        AppState.shared.reloadLibrary()
        return call
    }

    /// Jobs nobody collected within a day, e.g. after the agent gave up waiting.
    private static func removeOldJobs() {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-24 * 3600)
        guard let jobs = try? fm.contentsOfDirectory(at: KaikuAgents.jobsFolder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for job in jobs where FileJob.isValidID(job.lastPathComponent) {
            let modified = (try? job.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < limit { try? fm.removeItem(at: job) }
        }
    }
}
