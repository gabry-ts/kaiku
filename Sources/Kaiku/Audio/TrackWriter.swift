import AVFoundation
import KaikuCore
import os

/// Shared pause flag for both tracks: while paused, buffers are dropped on both
/// writers, so the two files stay aligned with each other. Also keeps the "active"
/// clock (time not paused) that writers use to fill gaps with silence.
final class PauseGate: Sendable {
    private struct State {
        var paused = false
        var pausedTotal: Double = 0
        var pausedSince: Double = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isPaused: Bool { state.withLock { $0.paused } }

    func set(_ value: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { s in
            guard s.paused != value else { return }
            if value { s.pausedSince = now } else { s.pausedTotal += now - s.pausedSince }
            s.paused = value
        }
    }

    /// Monotonic seconds, not counting time spent paused.
    func activeSeconds() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        return state.withLock { s in now - s.pausedTotal - (s.paused ? now - s.pausedSince : 0) }
    }
}

/// Writes one track as 16-bit PCM CAF while recording. An unfinished CAF is still
/// readable after a crash (the data chunk runs to the end of the file), so nothing
/// recorded is lost. The file is converted to AAC when the recording stops.
///
/// The file format is fixed by the first buffer. Later buffers in another format (a new
/// output device or microphone) are converted to it. When the source changes, the
/// time without audio is filled with silence, so both tracks stay aligned.
final class TrackWriter: @unchecked Sendable {
    let url: URL
    private let gate: PauseGate
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failed = false
    private(set) var framesWritten: AVAudioFramePosition = 0
    private var converter: AVAudioConverter?
    /// Active time the track's audio started at (first buffer's start).
    private var startActive: Double?
    /// Until this active time, any lag is treated as a source change and padded.
    private var gapArmedUntil: Double = 0
    private(set) var paddedSeconds: Double = 0

    init(url: URL, gate: PauseGate) {
        self.url = url
        self.gate = gate
    }

    /// Seconds written so far (audio and silence).
    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard let rate = file?.processingFormat.sampleRate else { return 0 }
        return Double(framesWritten) / rate
    }

    /// Call when the source is about to change: the next buffers pad the missing time.
    func expectGap() {
        let now = gate.activeSeconds()
        lock.lock()
        gapArmedUntil = now + 10
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard !gate.isPaused, buffer.frameLength > 0 else { return }
        let now = gate.activeSeconds()
        lock.lock()
        defer { lock.unlock() }
        if file == nil && !failed {
            do {
                file = try AVAudioFile(forWriting: url, settings: Self.pcmSettings(buffer.format),
                                       commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
            } catch {
                failed = true
                Log.audio.error("Could not create \(self.url.lastPathComponent, privacy: .public): \(error.diagnosticDescription, privacy: .public)")
            }
        }
        guard let file else { return }
        let target = file.processingFormat
        guard let out = buffer.format == target ? buffer : convert(buffer, to: target), out.frameLength > 0 else { return }
        let rate = target.sampleRate
        if startActive == nil { startActive = now - Double(out.frameLength) / rate }
        padIfNeeded(now: now, incoming: out.frameLength, file: file)
        do {
            try file.write(from: out)
            framesWritten += AVAudioFramePosition(out.frameLength)
        } catch {
            Log.audio.error("Write failed for \(self.url.lastPathComponent, privacy: .public): \(error.diagnosticDescription, privacy: .public)")
        }
    }

    /// Fills missing time with silence: always after an announced source change, and for
    /// any unannounced dropout longer than a second.
    private func padIfNeeded(now: Double, incoming: AVAudioFrameCount, file: AVAudioFile) {
        guard let startActive else { return }
        let rate = file.processingFormat.sampleRate
        let expected = (now - startActive) * rate
        let lagFrames = expected - Double(framesWritten + AVAudioFramePosition(incoming))
        let armed = now <= gapArmedUntil
        guard (armed && lagFrames > 0.04 * rate) || lagFrames > 1.0 * rate else { return }
        let frames = AVAudioFramePosition(min(lagFrames, 600 * rate))
        writeSilence(frames, to: file)
        gapArmedUntil = 0
        paddedSeconds += Double(frames) / rate
        Log.audio.info("\(self.url.lastPathComponent, privacy: .public): filled \(String(format: "%.3f", Double(frames) / rate), privacy: .public) s of silence after a source change")
    }

    private func writeSilence(_ frames: AVAudioFramePosition, to file: AVAudioFile) {
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            buffer.frameLength = n
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for b in list { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            do { try file.write(from: buffer) } catch { return }
            framesWritten += AVAudioFramePosition(n)
            remaining -= AVAudioFramePosition(n)
        }
    }

    /// Converts sample rate and channel count to the track's format.
    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            Log.audio.info("\(self.url.lastPathComponent, privacy: .public): converting \(buffer.format.description, privacy: .public) to \(target.description, privacy: .public)")
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    /// Closes the file, which finalizes the CAF header.
    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }

    static func pcmSettings(_ format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

/// Offline audio file work done with AVFoundation.
enum AudioFiles {
    private static let chunk: AVAudioFrameCount = 32_768

    /// Converts a (possibly unfinished) PCM file to AAC .m4a. Returns the duration in seconds.
    /// The source is left in place; the caller removes it once the result is verified.
    @discardableResult
    static func convertToM4A(_ source: URL, output: URL) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard input.length > 0 else { throw AudioCaptureError("\(source.lastPathComponent) has no audio") }
        let partial = output.deletingPathExtension().appendingPathExtension("partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        do {
            let out = try AVAudioFile(forWriting: partial,
                                      settings: AudioFileSettings.aac(sampleRate: format.sampleRate, channels: format.channelCount),
                                      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw AudioCaptureError("Could not allocate audio buffer")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
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
        let expected = Double(input.length) / format.sampleRate
        let got = Double(check.length) / check.processingFormat.sampleRate
        guard got >= expected - 1 else {
            throw AudioCaptureError("Converted \(output.lastPathComponent) is shorter than the recording (\(Int(got)) s of \(Int(expected)) s)")
        }
        return expected
    }

    static func duration(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Peak level per window of `window` seconds, and the total duration.
    static func peaks(_ url: URL, window: Double) throws -> (peaks: [Float], duration: Double) {
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
    static func writeRanges(_ source: URL, keep: [TimeRange], output: URL) throws {
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
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining)))
                if buffer.frameLength == 0 { break }
                try out.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
        }
    }
}
