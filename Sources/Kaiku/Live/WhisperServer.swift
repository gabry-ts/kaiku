import Darwin
import Foundation
import KaikuCore

/// A `whisper-server` kept running for the whole recording: the model is loaded once,
/// instead of once per chunk as `whisper-cli` would. Listens on 127.0.0.1 only.
final class WhisperServer: @unchecked Sendable {
    /// `whisper-server` next to the whisper-cli in use (the bundled one, or a custom build),
    /// the bundled one, or one in the usual Homebrew locations.
    static func detect() -> String? {
        let cli = AppSettings.whisperPath
        let sibling = cli.isEmpty ? nil : ((cli as NSString).deletingLastPathComponent as NSString).appendingPathComponent("whisper-server")
        let bundled = Bundle.main.path(forAuxiliaryExecutable: "whisper-server")
        return ([sibling, bundled].compactMap { $0 } + ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let missingHelp = "whisper-server not found. It ships with Kaiku; for a custom whisper-cli, put whisper-server next to it or install whisper.cpp with Homebrew (brew install whisper-cpp)."

    private let process: Process
    private let base: URL

    private init(process: Process, port: Int) {
        self.process = process
        self.base = URL(string: "http://127.0.0.1:\(port)")!
    }

    deinit { stop() }

    /// Starts the server and waits until the model is loaded.
    static func start(binary: String, model: String, language: String) async throws -> WhisperServer {
        guard let port = freePort() else { throw LiveEngineError("No free local port for whisper-server") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // Half the cores at most, so the call itself keeps running smoothly.
        let threads = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        process.arguments = ["-m", model, "--host", "127.0.0.1", "--port", String(port),
                             "-t", String(threads), "-l", language]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility
        try process.run()
        let server = WhisperServer(process: process, port: port)
        // Loading a large model can take a while the first time.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw LiveEngineError("whisper-server stopped while loading \((model as NSString).lastPathComponent) (\(process.terminationStatus))")
            }
            if await server.isUp() { return server }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        server.stop()
        throw LiveEngineError("whisper-server didn't start within two minutes")
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    private func isUp() async -> Bool {
        var req = URLRequest(url: base, timeoutInterval: 1)
        req.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Transcribes a 16 kHz mono WAV and returns the text.
    /// - Parameter audioContext: encoder frames for this clip (1500 = 30 s); a short clip
    ///   then costs what it lasts instead of a full 30 s window.
    func transcribe(wav: Data, language: String, audioContext: Int) async throws -> String {
        guard process.isRunning else { throw LiveEngineError("whisper-server is not running") }
        var form = MultipartForm()
        form.field("response_format", "json")
        form.field("temperature", "0.0")
        form.field("language", language)
        form.field("audio_ctx", String(audioContext))
        form.file("file", data: wav, filename: "chunk.wav", mime: "audio/wav")
        var req = URLRequest(url: base.appendingPathComponent("inference"), timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: req, from: form.finalized())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = json?["error"] as? String { throw LiveEngineError("whisper-server: \(error)") }
        guard status == 200, let text = json?["text"] as? String else {
            throw LiveEngineError("whisper-server failed (HTTP \(status))")
        }
        return text
    }

    /// Encoder frames for `seconds` of audio, rounded up, within whisper's 1500.
    static func audioContext(seconds: Double) -> Int {
        min(1500, max(64, Int((1500 * seconds / 30).rounded(.up)) + 32))
    }

    /// A TCP port free on 127.0.0.1 right now.
    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }
}
