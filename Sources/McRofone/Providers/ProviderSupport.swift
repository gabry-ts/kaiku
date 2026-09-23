import Foundation
import McRofoneCore

// MARK: - Provider readiness

enum ProviderReadiness: Equatable {
    case ready
    case needsKey
    case needsModel
    case needsBinary

    var text: String {
        switch self {
        case .ready: return "Ready"
        case .needsKey: return "API key missing"
        case .needsModel: return "Model missing"
        case .needsBinary: return "whisper-cli not found"
        }
    }
}

extension ProviderKind {
    var readiness: ProviderReadiness {
        switch self {
        case .whisperCpp:
            if !FileManager.default.isExecutableFile(atPath: AppSettings.whisperPath) { return .needsBinary }
            if !FileManager.default.fileExists(atPath: AppSettings.whisperModel) { return .needsModel }
            return .ready
        default:
            return Keychain.apiKey(for: self) == nil ? .needsKey : .ready
        }
    }

    var symbol: String {
        switch self {
        case .whisperCpp: return "desktopcomputer"
        case .elevenLabs: return "waveform"
        case .openAI: return "sparkles"
        case .groq: return "bolt.fill"
        }
    }

    var tagline: String {
        switch self {
        case .whisperCpp: return "Private and free. Runs on this Mac."
        case .elevenLabs: return "Scribe, with speaker detection."
        case .openAI: return "gpt-4o-transcribe and Whisper."
        case .groq: return "Very fast Whisper in the cloud."
        }
    }

    /// Suggested model ids for the model picker.
    var modelPresets: [String] {
        switch self {
        case .whisperCpp: return []
        case .elevenLabs: return ["scribe_v2", "scribe_v1"]
        case .openAI: return ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe-diarize", "whisper-1"]
        case .groq: return ["whisper-large-v3-turbo", "whisper-large-v3"]
        }
    }

    var keyURL: URL? {
        switch self {
        case .whisperCpp: return nil
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        }
    }
}

/// Runs a tiny real transcription (1 s tone) to check a provider end to end.
enum ProviderTester {
    static func test(_ kind: ProviderKind) async -> (ok: Bool, message: String) {
        do {
            let provider = try ProviderFactory.make(kind)
            let dir = try AudioTools.makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let tone = dir.appendingPathComponent("test.m4a")
            try await Shell.run(AudioTools.ffmpeg, [
                "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                "-c:a", "aac", tone.path,
            ])
            let start = Date()
            _ = try await provider.transcribe(fileURL: tone, language: nil, diarize: false)
            let secs = Date().timeIntervalSince(start)
            return (true, String(format: "Works. Answered in %.1f s.", secs))
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

// MARK: - whisper.cpp models

struct WhisperModel: Identifiable, Hashable {
    let file: String
    let name: String
    let size: String
    let note: String
    var id: String { file }

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }
    var localURL: URL { WhisperModels.directory.appendingPathComponent(file) }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    static let catalog: [WhisperModel] = [
        WhisperModel(file: "ggml-tiny.bin", name: "Tiny", size: "75 MB", note: "Fastest, rough quality"),
        WhisperModel(file: "ggml-base.bin", name: "Base", size: "142 MB", note: "Fast, basic quality"),
        WhisperModel(file: "ggml-small.bin", name: "Small", size: "466 MB", note: "Good balance"),
        WhisperModel(file: "ggml-medium.bin", name: "Medium", size: "1.5 GB", note: "Accurate, slower"),
        WhisperModel(file: "ggml-large-v3-turbo-q5_0.bin", name: "Large v3 Turbo (compact)", size: "547 MB", note: "Great quality, fast"),
        WhisperModel(file: "ggml-large-v3-turbo.bin", name: "Large v3 Turbo", size: "1.6 GB", note: "Best quality"),
    ]

    static let recommended = catalog[4]
}

/// Downloads ggml models with progress into ~/Library/Application Support/mc.Rofone/models.
@MainActor
final class WhisperModels: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = WhisperModels()

    nonisolated static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/mc.Rofone/models", isDirectory: true)
    }

    /// Download progress 0...1 by model file name.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var version = 0

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var tasks: [String: URLSessionDownloadTask] = [:]

    var activeFile: String { (AppSettings.whisperModel as NSString).lastPathComponent }

    func isActive(_ model: WhisperModel) -> Bool { AppSettings.whisperModel == model.localURL.path }

    func use(_ model: WhisperModel) {
        AppSettings.defaults.set(model.localURL.path, forKey: Keys.whisperModel)
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

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let file = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated { self.progress[file] = value }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let file = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let dest = WhisperModels.directory.appendingPathComponent(file)
        var failure: String?
        if status == 200 {
            do {
                try FileManager.default.createDirectory(at: WhisperModels.directory, withIntermediateDirectories: true)
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
            if failure == nil, !FileManager.default.fileExists(atPath: AppSettings.whisperModel),
               let model = WhisperModel.catalog.first(where: { $0.file == file }) {
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

    /// Finds whisper-cli in the usual Homebrew locations.
    nonisolated static func detectWhisperCLI() -> String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
