import Foundation
import KaikuCore
import Observation

extension WhisperModel {
    /// The models offered on the iPhone: the big ones are too heavy for it.
    static let phoneCatalog: [WhisperModel] = catalog.filter {
        ["ggml-tiny.bin", "ggml-base.bin", "ggml-small.bin", "ggml-large-v3-turbo-q5_0.bin"].contains($0.file)
    }

    var localURL: URL { WhisperDownloader.directory.appendingPathComponent(file) }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: localURL.path) }
}

/// Downloads ggml models into Application Support/models, with progress.
@MainActor
@Observable
final class WhisperDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = WhisperDownloader()

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Download progress 0...1 by model file name.
    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    /// Changes whenever a model is added or removed, so views refresh.
    private(set) var version = 0

    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]

    nonisolated static var activeFile: String { UserDefaults.standard.string(forKey: PhoneKeys.whisperModel) ?? "" }

    /// The model transcription uses: the chosen one if installed, else any installed one.
    nonisolated static var activeModel: WhisperModel? {
        let installed = WhisperModel.phoneCatalog.filter(\.isInstalled)
        return installed.first { $0.file == activeFile } ?? installed.first
    }

    func use(_ model: WhisperModel) {
        UserDefaults.standard.set(model.file, forKey: PhoneKeys.whisperModel)
        version += 1
    }

    func download(_ model: WhisperModel) {
        guard tasks[model.file] == nil else { return }
        errors[model.file] = nil
        progress[model.file] = 0
        let task = session.downloadTask(with: model.url)
        task.taskDescription = model.file
        tasks[model.file] = task
        task.resume()
    }

    func cancel(_ model: WhisperModel) {
        tasks[model.file]?.cancel()
        tasks[model.file] = nil
        progress[model.file] = nil
    }

    func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: model.localURL)
        version += 1
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let file = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated { self.progress[file] = value }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let file = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let dest = WhisperDownloader.directory.appendingPathComponent(file)
        var failure: String?
        if status == 200 {
            do {
                try FileManager.default.createDirectory(at: WhisperDownloader.directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: location)
                } else {
                    try FileManager.default.moveItem(at: location, to: dest)
                }
            } catch { failure = error.localizedDescription }
        } else {
            failure = "Download failed (HTTP \(status))"
        }
        MainActor.assumeIsolated {
            self.tasks[file] = nil
            self.progress[file] = nil
            self.errors[file] = failure
            if failure == nil, let model = WhisperModel.phoneCatalog.first(where: { $0.file == file }), Self.activeModel?.file != Self.activeFile {
                self.use(model)
            }
            self.version += 1
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let file = task.taskDescription, let error else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        MainActor.assumeIsolated {
            self.tasks[file] = nil
            self.progress[file] = nil
            if !cancelled { self.errors[file] = error.localizedDescription }
        }
    }
}
