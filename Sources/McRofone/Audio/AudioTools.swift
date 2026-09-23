import Foundation

struct ProcessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Shell {
    /// Runs an executable and waits for it. Output goes to temp files to avoid pipe deadlocks.
    /// Returns stdout; throws with stderr tail on non-zero exit.
    @discardableResult
    static func run(_ executable: String, _ args: [String]) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError(message: "Executable not found: \(executable)")
        }
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent(UUID().uuidString + ".out")
        let errURL = tmp.appendingPathComponent(UUID().uuidString + ".err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
        try? outHandle.close()
        try? errHandle.close()

        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        if status != 0 {
            let err = ((try? String(contentsOf: errURL, encoding: .utf8)) ?? "").suffix(800)
            throw ProcessError(message: "\((executable as NSString).lastPathComponent) failed (\(status)): \(err)")
        }
        return out
    }
}

/// ffmpeg / ffprobe helpers.
enum AudioTools {
    static var ffmpeg: String { AppSettings.ffmpegPath }
    static var ffprobe: String {
        (AppSettings.ffmpegPath as NSString).deletingLastPathComponent + "/ffprobe"
    }

    static func duration(of url: URL) async -> Double? {
        let out = try? await Shell.run(ffprobe, [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ])
        return out.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// 16 kHz mono 16-bit WAV, as required by whisper.cpp.
    static func toWhisperWav(_ input: URL, output: URL) async throws {
        try await Shell.run(ffmpeg, [
            "-y", "-loglevel", "error", "-i", input.path,
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", output.path,
        ])
    }

    /// Mono 16 kHz low-bitrate MP3, small enough for upload APIs.
    static func compress(_ input: URL, output: URL) async throws {
        try await Shell.run(ffmpeg, [
            "-y", "-loglevel", "error", "-i", input.path,
            "-ac", "1", "-ar", "16000", "-c:a", "libmp3lame", "-b:a", "32k", output.path,
        ])
    }

    /// Splits into compressed MP3 chunks of `seconds` length.
    /// Returns chunk URLs with their start offsets (measured with ffprobe).
    static func chunks(_ input: URL, seconds: Int, dir: URL) async throws -> [(url: URL, offset: Double, duration: Double)] {
        let pattern = dir.appendingPathComponent("chunk_%03d.mp3").path
        try await Shell.run(ffmpeg, [
            "-y", "-loglevel", "error", "-i", input.path,
            "-ac", "1", "-ar", "16000", "-c:a", "libmp3lame", "-b:a", "32k",
            "-f", "segment", "-segment_time", String(seconds), "-reset_timestamps", "1", pattern,
        ])
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("chunk_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result: [(URL, Double, Double)] = []
        var offset = 0.0
        for f in files {
            let d = await duration(of: f) ?? Double(seconds)
            result.append((f, offset, d))
            offset += d
        }
        return result
    }

    /// Mixes mic and system tracks into one file for listening.
    static func mix(mic: URL, system: URL, output: URL) async throws {
        try await Shell.run(ffmpeg, [
            "-y", "-loglevel", "error", "-i", mic.path, "-i", system.path,
            "-filter_complex", "amix=inputs=2:duration=longest:normalize=0",
            "-c:a", "aac", "-b:a", "128k", output.path,
        ])
    }

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcrofone-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
