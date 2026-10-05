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
        var origin: Double?
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

    /// Marks the start of the recording: both tracks pad their first buffer back to it,
    /// so they start together however long each source took to open.
    func markOrigin() {
        let now = activeSeconds()
        state.withLock { $0.origin = now }
    }

    var origin: Double? { state.withLock { $0.origin } }

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
    private var error: String?
    /// Gets a copy of every buffer written, with its start in the file in seconds.
    /// Only set when live transcription is on; called on the audio thread.
    private let tap: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?

    init(url: URL, gate: PauseGate, tap: (@Sendable (AVAudioPCMBuffer, Double) -> Void)? = nil) {
        self.url = url
        self.gate = gate
        self.tap = tap
    }

    /// Seconds written so far (audio and silence).
    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard let rate = file?.processingFormat.sampleRate else { return 0 }
        return Double(framesWritten) / rate
    }

    /// The first error that cost audio (file not created, write failed), if any.
    var writeError: String? {
        lock.lock()
        defer { lock.unlock() }
        return error
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
                if self.error == nil { self.error = "Could not create \(url.lastPathComponent): \(error.diagnosticDescription)" }
                Log.audio.error("Could not create \(self.url.lastPathComponent, privacy: .public): \(error.diagnosticDescription, privacy: .public)")
            }
        }
        guard let file else { return }
        let target = file.processingFormat
        guard let out = buffer.format == target ? buffer : convert(buffer, to: target), out.frameLength > 0 else { return }
        let rate = target.sampleRate
        if startActive == nil {
            let first = now - Double(out.frameLength) / rate
            if let origin = gate.origin, first > origin, first - origin < 10 {
                // Pad back to the shared start, so both tracks line up.
                startActive = origin
                gapArmedUntil = now + 1
            } else {
                startActive = first
            }
        }
        padIfNeeded(now: now, incoming: out.frameLength, file: file)
        do {
            try file.write(from: out)
            if let tap, let copy = Self.copy(out) { tap(copy, Double(framesWritten) / rate) }
            framesWritten += AVAudioFramePosition(out.frameLength)
        } catch {
            if self.error == nil { self.error = "Write failed for \(url.lastPathComponent): \(error.diagnosticDescription)" }
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

    /// A buffer that owns its samples, so it outlives the capture callback.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { return nil }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
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
