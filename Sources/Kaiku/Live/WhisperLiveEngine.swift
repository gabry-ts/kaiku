import AVFoundation
import KaikuCore
import os

/// Live transcription with whisper.cpp, on device. whisper can't take a stream, so the
/// audio of each track is cut into chunks of about twelve seconds that overlap, and
/// `whisper-cli` runs on one chunk at a time with low priority. The text shows up some
/// ten seconds after it was said.
final class WhisperLiveEngine: LiveEngine, @unchecked Sendable {
    static let sampleRate = 16_000

    /// Whether whisper can run, in the words the transcription settings use.
    static var readiness: LiveReadiness {
        switch ProviderKind.whisperCpp.readiness {
        case .ready: return .ready
        case .needsModel: return .unavailable("\(ProviderReadiness.needsModel.text). Download a whisper.cpp model in Settings > Transcription.")
        case let other: return .unavailable("\(other.text). Set it up in Settings > Transcription.")
        }
    }

    let events: AsyncStream<LiveEvent>
    private let report: AsyncStream<LiveEvent>.Continuation

    private struct Input: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let track: LiveTrack
        let time: Double
    }

    /// The audio of one track not transcribed yet.
    private struct Track {
        var planner = ChunkPlanner(sampleRate: WhisperLiveEngine.sampleRate)
        var samples: [Int16] = []
        /// Index of `samples[0]` in the track.
        var offset = 0
        var timeline = LiveTimeline()
        /// Text and end of the last chunk transcribed, to tell the overlapped words.
        var lastText = ""
        var lastEnd = -1
    }

    /// A chunk on its way to whisper.
    private struct Job {
        let track: LiveTrack
        let samples: [Int16]
        let start: Double
        let end: Double
        /// The text of the chunk right before, empty when that one was skipped.
        let previous: String
    }

    private struct State {
        var tracks: [LiveTrack: Track] = [:]
        var workers: [Task<Void, Never>] = []
        var process: Process?
        var stopped = false
        /// Set when the recording can't wait for the chunks left.
        var abandoned = false
        var dir: URL?
    }

    private let audio: AsyncStream<Input>
    private let feeder: AsyncStream<Input>.Continuation
    /// Tells the whisper loop that a chunk may be ready.
    private let wake: AsyncStream<Void>
    private let waker: AsyncStream<Void>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let binary = AppSettings.whisperPath
    private let model = AppSettings.whisperModel

    init() {
        (events, report) = AsyncStream<LiveEvent>.makeStream()
        // About a minute of audio can wait to be cut into chunks.
        (audio, feeder) = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingNewest(8000))
        (wake, waker) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        feeder.finish()
        waker.finish()
        report.finish()
        if let dir = state.withLock({ $0.dir }) { try? FileManager.default.removeItem(at: dir) }
    }

    func start(language: String) async throws {
        if case .unavailable(let why) = Self.readiness { throw LiveEngineError(why) }
        let dir = try AudioTools.makeTempDir()
        Log.transcription.info("Live transcription with whisper.cpp (\((self.model as NSString).lastPathComponent, privacy: .public))")
        let started = state.withLock { s -> Bool in
            guard !s.stopped else { return false }
            s.dir = dir
            s.workers = [Task { await self.cut() }, Task { await self.transcribe(language: language, dir: dir) }]
            return true
        }
        if !started { try? FileManager.default.removeItem(at: dir) }
    }

    func feed(_ buffer: AVAudioPCMBuffer, track: LiveTrack, at time: Double) {
        feeder.yield(Input(buffer: buffer, track: track, time: time))
    }

    func stop() async {
        feeder.finish()
        let (workers, dir) = state.withLock { s -> ([Task<Void, Never>], URL?) in
            s.stopped = true
            defer { s.workers = [] }
            return (s.workers, s.dir)
        }
        // When the caller stops waiting, whisper is ended and the chunks left are dropped.
        await withTaskCancellationHandler {
            for worker in workers { await worker.value }
        } onCancel: {
            self.abandon()
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
        report.finish()
    }

    private func abandon() {
        let process = state.withLock { s -> Process? in
            s.abandoned = true
            return s.process
        }
        if process?.isRunning == true { process?.terminate() }
    }

    /// Converts the audio as it arrives and plans the chunks of each track.
    private func cut() async {
        var converters: [LiveTrack: LivePCMConverter] = [:]
        let rate = Self.sampleRate
        do {
            for await input in audio {
                if converters[input.track] == nil { converters[input.track] = try LivePCMConverter(sampleRate: rate) }
                guard let samples = try converters[input.track]?.convert(input.buffer), !samples.isEmpty else { continue }
                let dropped = state.withLock { s -> Int in
                    var track = s.tracks[input.track] ?? Track()
                    let before = track.planner.dropped
                    track.timeline.note(recorded: input.time, duration: Double(samples.count) / Double(rate))
                    track.samples += samples
                    track.planner.add(samples.count)
                    // Forget the audio no chunk needs any more, a second at a time.
                    let old = track.planner.keepFrom - track.offset
                    if old >= rate {
                        track.samples.removeFirst(min(old, track.samples.count))
                        track.offset += old
                    }
                    s.tracks[input.track] = track
                    return track.planner.dropped - before
                }
                if dropped > 0 { Log.transcription.info("Live transcription is behind: dropped \(dropped) chunk(s)") }
                waker.yield()
            }
        } catch {
            fail(error.localizedDescription)
        }
        state.withLock { s in
            for track in Array(s.tracks.keys) { s.tracks[track]?.planner.finish(minimum: rate) }
        }
        waker.finish()
    }

    /// Runs whisper on the chunks as they are ready, never more than one at a time.
    private func transcribe(language: String, dir: URL) async {
        var failures = 0
        func drain() async {
            while let job = next() {
                do {
                    try await run(job, language: language, dir: dir)
                    failures = 0
                } catch {
                    guard !state.withLock({ $0.abandoned }) else { return }
                    failures += 1
                    Log.transcription.error("Live whisper chunk failed: \(error.localizedDescription, privacy: .public)")
                    // One bad chunk is skipped; two in a row mean whisper doesn't work.
                    if failures >= 2 {
                        fail(error.localizedDescription)
                        return
                    }
                }
            }
        }
        for await _ in wake { await drain() }
        await drain()
    }

    /// The oldest chunk waiting across the tracks.
    private func next() -> Job? {
        let rate = Double(Self.sampleRate)
        return state.withLock { s -> Job? in
            guard !s.abandoned else { return nil }
            let waiting = s.tracks.compactMap { track, t in
                t.planner.pending.first.map { (track, t.timeline.recordedTime(Double($0.fresh) / rate)) }
            }
            guard let track = waiting.min(by: { $0.1 < $1.1 })?.0, var t = s.tracks[track], let chunk = t.planner.take() else { return nil }
            let from = max(0, chunk.start - t.offset)
            let to = min(t.samples.count, chunk.end - t.offset)
            let job = Job(track: track, samples: from < to ? Array(t.samples[from..<to]) : [],
                          start: t.timeline.recordedTime(Double(chunk.fresh) / rate),
                          end: t.timeline.recordedTime(Double(chunk.end) / rate),
                          previous: chunk.fresh == t.lastEnd ? t.lastText : "")
            t.lastEnd = chunk.end
            t.lastText = ""
            s.tracks[track] = t
            return job
        }
    }

    private func run(_ job: Job, language: String, dir: URL) async throws {
        // whisper makes words up when given silence.
        guard !ChunkAudio.isSilent(job.samples, sampleRate: Self.sampleRate) else { return }
        let wav = dir.appendingPathComponent("chunk.wav")
        let outBase = dir.appendingPathComponent("chunk")
        let json = outBase.appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: json)
        }
        try ChunkAudio.wav(job.samples, sampleRate: Self.sampleRate).write(to: wav)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // Half the cores at most, so the call itself keeps running smoothly.
        let threads = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        process.arguments = ["-m", model, "-f", wav.path, "-l", language, "-t", String(threads), "-oj", "-of", outBase.path, "-np"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
                state.withLock { $0.process = process }
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        let abandoned = state.withLock { s -> Bool in
            s.process = nil
            return s.abandoned
        }
        if abandoned { throw CancellationError() }
        // As in the offline provider: whisper can abort at exit after writing its output.
        guard let data = try? Data(contentsOf: json), let result = try? ResponseParsers.whisperCpp(data) else {
            throw LiveEngineError("whisper-cli failed (\(status))")
        }
        let heard = OverlapText.spoken(result.segments.map(\.text).joined(separator: " "))
        state.withLock { $0.tracks[job.track]?.lastText = heard }
        let text = OverlapText.trim(heard, after: job.previous)
        if !text.isEmpty { report.yield(.final(job.track, text, start: job.start, end: job.end)) }
    }

    /// Reports the failure and stops taking audio.
    private func fail(_ message: String) {
        report.yield(.failed("Live transcription stopped: \(message)"))
        feeder.finish()
        state.withLock { $0.abandoned = true }
    }
}
