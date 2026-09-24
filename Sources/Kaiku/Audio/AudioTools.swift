import AVFoundation
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

/// Offline conversions for the transcription providers, done with AVFoundation.
enum AudioTools {
    /// Sample rate used for everything sent to speech-to-text.
    static let speechRate: Double = 16_000

    /// 16 kHz mono 16-bit WAV, as required by whisper.cpp.
    static func toWhisperWav(_ input: URL, output: URL) async throws {
        try await detached {
            let reader = try PCMReader(url: input, sampleRate: speechRate, channels: 1)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: speechRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let out = try AVAudioFile(forWriting: output, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            while let buffer = try reader.read() { try out.write(from: buffer) }
        }
    }

    /// Mono 16 kHz low-bitrate AAC (.m4a), small enough for upload APIs.
    static func compress(_ input: URL, output: URL) async throws {
        try await detached {
            let reader = try PCMReader(url: input, sampleRate: speechRate, channels: 1)
            let out = try speechFile(output)
            while let buffer = try reader.read() { try out.write(from: buffer) }
        }
    }

    /// Splits into compressed mono 16 kHz AAC chunks of `seconds` length.
    /// Returns chunk URLs with their start offsets and durations.
    static func chunks(_ input: URL, seconds: Int, dir: URL) async throws -> [(url: URL, offset: Double, duration: Double)] {
        try await detached {
            let reader = try PCMReader(url: input, sampleRate: speechRate, channels: 1)
            let perChunk = AVAudioFramePosition(seconds) * AVAudioFramePosition(speechRate)
            var result: [(url: URL, offset: Double, duration: Double)] = []
            var file: AVAudioFile?
            var written: AVAudioFramePosition = 0
            var total: AVAudioFramePosition = 0

            func finish() {
                guard let f = file else { return }
                let offset = Double(total - written) / speechRate
                result.append((f.url, offset, Double(written) / speechRate))
                file = nil
                written = 0
            }

            while let buffer = try reader.read() {
                var start: AVAudioFrameCount = 0
                while start < buffer.frameLength {
                    if file == nil {
                        let name = String(format: "chunk_%03d.m4a", result.count)
                        file = try speechFile(dir.appendingPathComponent(name))
                    }
                    let room = AVAudioFrameCount(perChunk - written)
                    let n = min(room, buffer.frameLength - start)
                    try file?.write(from: buffer.slice(from: start, count: n))
                    start += n
                    written += AVAudioFramePosition(n)
                    total += AVAudioFramePosition(n)
                    if written >= perChunk { finish() }
                }
            }
            finish()
            return result
        }
    }

    /// Mixes mic and system tracks into one AAC file for listening. The result is as
    /// long as the longer track; samples are summed without normalization.
    static func mix(mic: URL, system: URL, output: URL) async throws {
        try await detached {
            let a = try AVAudioFile(forReading: mic).processingFormat
            let b = try AVAudioFile(forReading: system).processingFormat
            let rate = max(a.sampleRate, b.sampleRate)
            let channels = min(max(a.channelCount, b.channelCount), 2)
            let micReader = try PCMReader(url: mic, sampleRate: rate, channels: channels)
            let systemReader = try PCMReader(url: system, sampleRate: rate, channels: channels)
            let partial = output.deletingPathExtension().appendingPathExtension("partial.m4a")
            try? FileManager.default.removeItem(at: partial)
            do {
                let out = try aacFile(partial, sampleRate: rate, channels: channels, bitRate: 128_000)
                var micDone = false, systemDone = false
                while !(micDone && systemDone) {
                    let m = micDone ? nil : try micReader.read()
                    let s = systemDone ? nil : try systemReader.read()
                    if m == nil { micDone = true }
                    if s == nil { systemDone = true }
                    guard let sum = PCMReader.sum(m, s) else { continue }
                    try out.write(from: sum)
                }
            }
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: output)
            }
        }
    }

    /// Writes a sine tone (or silence with `amplitude` 0) as AAC .m4a.
    static func writeTone(_ output: URL, seconds: Double, frequency: Double = 440, amplitude: Float = 0.3,
                          sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let out = try AVAudioFile(forWriting: output, settings: AudioFileSettings.aac(sampleRate: sampleRate, channels: channels),
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = AVAudioFramePosition(seconds * sampleRate)
        let block: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
            throw AudioCaptureError("Could not allocate audio buffer")
        }
        var position: AVAudioFramePosition = 0
        while position < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(block), total - position))
            buffer.frameLength = n
            for i in 0..<Int(n) {
                let v = amplitude * Float(sin(2 * Double.pi * frequency * Double(position + AVAudioFramePosition(i)) / sampleRate))
                for c in 0..<Int(channels) { buffer.floatChannelData![c][i] = v }
            }
            try out.write(from: buffer)
            position += AVAudioFramePosition(n)
        }
    }

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaiku-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Helpers

    private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    /// Mono 16 kHz AAC at 32 kbps.
    private static func speechFile(_ url: URL) throws -> AVAudioFile {
        try aacFile(url, sampleRate: speechRate, channels: 1, bitRate: 32_000)
    }

    /// AAC file at `bitRate`, or at the encoder's quality-based rate if that bit rate is
    /// not valid for this sample rate and channel count.
    private static func aacFile(_ url: URL, sampleRate: Double, channels: AVAudioChannelCount, bitRate: Int) throws -> AVAudioFile {
        var settings = AudioFileSettings.aac(sampleRate: sampleRate, channels: channels)
        settings[AVEncoderBitRateKey] = bitRate
        settings[AVEncoderAudioQualityKey] = nil
        if let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
            return file
        }
        try? FileManager.default.removeItem(at: url)
        return try AVAudioFile(forWriting: url, settings: AudioFileSettings.aac(sampleRate: sampleRate, channels: channels),
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}

/// Reads any audio file as deinterleaved Float32 buffers at a given sample rate and
/// channel count (resampled and down- or up-mixed as needed).
final class PCMReader {
    static let block: AVAudioFrameCount = 16_384

    let format: AVAudioFormat
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private var ended = false

    init(url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws {
        file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.block) else {
            throw AudioCaptureError("Cannot convert \(url.lastPathComponent)")
        }
        converter.downmix = true
        format = target
        self.converter = converter
        self.input = input
    }

    /// The next buffer of `block` frames (fewer at the end), or nil at the end of the file.
    func read() throws -> AVAudioPCMBuffer? {
        guard !ended else { return nil }
        // Every buffer except the last holds exactly `block` frames, so readers at
        // different source rates stay aligned.
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.block) else {
            throw AudioCaptureError("Could not allocate audio buffer")
        }
        var readError: Error?
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { [file, input] _, status in
            if file.framePosition >= file.length {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: Self.block)
            } catch {
                readError = error
                status.pointee = .endOfStream
                return nil
            }
            if input.frameLength == 0 {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return input
        }
        if let readError { throw readError }
        if let error { throw error }
        if status == .error { throw AudioCaptureError("Audio conversion failed") }
        if status == .endOfStream { ended = true }
        return out.frameLength > 0 ? out : (ended ? nil : try read())
    }

    /// Sample-wise sum of two buffers in the same format; the result is as long as the longer one.
    static func sum(_ a: AVAudioPCMBuffer?, _ b: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard let first = a ?? b else { return nil }
        guard let a, let b else { return first }
        let n = max(a.frameLength, b.frameLength)
        guard let out = AVAudioPCMBuffer(pcmFormat: a.format, frameCapacity: n) else { return nil }
        out.frameLength = n
        for c in 0..<Int(a.format.channelCount) {
            let o = out.floatChannelData![c]
            for i in 0..<Int(n) {
                let x = i < Int(a.frameLength) ? a.floatChannelData![c][i] : 0
                let y = i < Int(b.frameLength) ? b.floatChannelData![c][i] : 0
                o[i] = x + y
            }
        }
        return out
    }
}

extension AVAudioPCMBuffer {
    /// A copy of `count` frames starting at `start` (deinterleaved Float32 only).
    func slice(from start: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer {
        if start == 0 && count == frameLength { return self }
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        out.frameLength = count
        for c in 0..<Int(format.channelCount) {
            out.floatChannelData![c].update(from: floatChannelData![c] + Int(start), count: Int(count))
        }
        return out
    }
}
