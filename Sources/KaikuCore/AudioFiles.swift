import AVFoundation
import Foundation

/// Offline audio file work done with AVFoundation.
public enum AudioFiles {
    private static let chunk: AVAudioFrameCount = 32_768

    /// Converts a (possibly unfinished) PCM file to AAC .m4a, keeping at most `maxSeconds`.
    /// Returns the duration in seconds. The source is left in place; the caller removes it
    /// once the result is verified.
    @discardableResult
    public static func convertToM4A(_ source: URL, output: URL, maxSeconds: Double? = nil) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard input.length > 0 else { throw AudioCaptureError("\(source.lastPathComponent) has no audio") }
        let length = maxSeconds.map { min(input.length, max(1, AVAudioFramePosition($0 * format.sampleRate))) } ?? input.length
        let partial = output.deletingPathExtension().appendingPathExtension("partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        do {
            let out = try AVAudioFile(forWriting: partial,
                                      settings: AudioFileSettings.aac(sampleRate: format.sampleRate, channels: format.channelCount),
                                      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw AudioCaptureError("Could not allocate audio buffer")
            }
            while input.framePosition < length {
                try input.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(length - input.framePosition)))
                if buffer.frameLength == 0 { break }
                try out.write(from: buffer)
            }
        }
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: output)
        }
        let check = try AVAudioFile(forReading: output)
        let expected = Double(length) / format.sampleRate
        let got = Double(check.length) / check.processingFormat.sampleRate
        guard got >= expected - 1 else {
            throw AudioCaptureError("Converted \(output.lastPathComponent) is shorter than the recording (\(Int(got)) s of \(Int(expected)) s)")
        }
        return expected
    }

    public static func duration(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Peak level per window of `window` seconds, and the total duration.
    public static func peaks(_ url: URL, window: Double) throws -> (peaks: [Float], duration: Double) {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let windowFrames = max(1, Int(format.sampleRate * window))
        let capacity = AVAudioFrameCount(windowFrames * 40)
        guard format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioCaptureError("Unsupported format for silence detection")
        }
        var peaks: [Float] = []
        var current: Float = 0
        var inWindow = 0
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: capacity)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            let channels = Int(format.channelCount)
            let interleaved = format.isInterleaved
            guard let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                if interleaved {
                    for c in 0..<channels { current = max(current, abs(data[0][i * channels + c])) }
                } else {
                    for c in 0..<channels { current = max(current, abs(data[c][i])) }
                }
                inWindow += 1
                if inWindow == windowFrames {
                    peaks.append(current)
                    current = 0
                    inWindow = 0
                }
            }
        }
        if inWindow > 0 { peaks.append(current) }
        return (peaks, Double(input.length) / format.sampleRate)
    }

    /// Writes only the `keep` ranges of `source`, back to back, as AAC.
    public static func writeRanges(_ source: URL, keep: [TimeRange], output: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let out = try AVAudioFile(forWriting: output,
                                  settings: AudioFileSettings.aac(sampleRate: format.sampleRate, channels: format.channelCount),
                                  commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AudioCaptureError("Could not allocate audio buffer")
        }
        for r in keep {
            let start = AVAudioFramePosition(r.start * format.sampleRate)
            let end = min(input.length, AVAudioFramePosition(r.end * format.sampleRate))
            guard end > start else { continue }
            input.framePosition = start
            var remaining = end - start
            while remaining > 0 {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining)))
                if buffer.frameLength == 0 { break }
                try out.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
        }
    }
}

public enum AudioFileSettings {
    /// AAC settings. No fixed bit rate on purpose: valid AAC bit rates depend on the
    /// sample rate (e.g. 64 kbps is rejected at 16 kHz, which Bluetooth headsets use),
    /// so the encoder picks one from the quality setting.
    public static func aac(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: min(Int(channels), 2),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }
}

/// Audio of any file AVFoundation can read, saved as AAC .m4a.
public enum MediaAudio {
    public static func extract(from source: URL, to output: URL) async throws {
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
        if #available(macOS 15, iOS 18, *) {
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
