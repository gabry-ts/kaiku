import AVFoundation
import CoreMedia
import KaikuCore
import os
import Speech

/// Live transcription with the system speech recognizer, on device. Each track gets its
/// own analyzer, created when its first audio arrives, so a call without a microphone
/// track loads one model only.
@available(macOS 26, *)
final class AppleLiveEngine: LiveEngine, @unchecked Sendable {
    let events: AsyncStream<LiveEvent>
    private let report: AsyncStream<LiveEvent>.Continuation

    private struct Chunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let time: Double
    }

    private struct State {
        var workers: [Task<Void, Never>] = []
        var stopped = false
    }

    private let audio: [LiveTrack: AsyncStream<Chunk>]
    private let feeders: [LiveTrack: AsyncStream<Chunk>.Continuation]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        (events, report) = AsyncStream<LiveEvent>.makeStream()
        var audio: [LiveTrack: AsyncStream<Chunk>] = [:]
        var feeders: [LiveTrack: AsyncStream<Chunk>.Continuation] = [:]
        for track in LiveTrack.allCases {
            // About half a minute of audio can wait for the recognizer; older audio is dropped.
            let (stream, continuation) = AsyncStream<Chunk>.makeStream(bufferingPolicy: .bufferingNewest(4000))
            audio[track] = stream
            feeders[track] = continuation
        }
        self.audio = audio
        self.feeders = feeders
    }

    deinit {
        feeders.values.forEach { $0.finish() }
        report.finish()
    }

    func start(language: String) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw LiveEngineError("The system speech recognizer isn't available on this Mac.")
        }
        guard let locale = await AppleSpeech.locale(for: language) else {
            throw LiveEngineError("The system speech recognizer doesn't support \(AppleSpeech.name(ofLanguage: language)).")
        }
        // Never download during a call: that is done from Settings.
        guard await AppleSpeech.isInstalled(locale) else {
            throw LiveEngineError("The speech model for \(AppleSpeech.name(locale)) isn't downloaded. Get it in Settings > Live.")
        }
        Log.transcription.info("Live transcription in \(locale.identifier, privacy: .public)")
        state.withLock { s in
            guard !s.stopped else { return }
            s.workers = LiveTrack.allCases.map { track in Task { await self.run(track, locale: locale) } }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer, track: LiveTrack, at time: Double) {
        feeders[track]?.yield(Chunk(buffer: buffer, time: time))
    }

    func stop() async {
        feeders.values.forEach { $0.finish() }
        let workers = state.withLock { s -> [Task<Void, Never>] in
            s.stopped = true
            defer { s.workers = [] }
            return s.workers
        }
        for worker in workers { await worker.value }
        report.finish()
    }

    /// One track from its first buffer to the end of the recording.
    private func run(_ track: LiveTrack, locale: Locale) async {
        guard let audio = audio[track] else { return }
        var pipeline: Pipeline?
        do {
            for await chunk in audio {
                if pipeline == nil {
                    pipeline = try await Pipeline(track: track, locale: locale, natural: chunk.buffer.format, report: report) { [weak self] error in
                        self?.fail(track, error)
                    }
                }
                try pipeline?.feed(chunk.buffer, at: chunk.time)
            }
            try await pipeline?.finish()
        } catch {
            await pipeline?.cancel()
            fail(track, error)
        }
    }

    /// Reports the failure and stops taking audio, which ends both tracks.
    private func fail(_ track: LiveTrack, _ error: Error) {
        let source = track == .me ? "microphone" : "call audio"
        report.yield(.failed("Live transcription stopped (\(source)): \(error.localizedDescription)"))
        feeders.values.forEach { $0.finish() }
    }

    /// An analyzer with its transcriber, fed the audio of one track.
    private final class Pipeline: @unchecked Sendable {
        private let analyzer: SpeechAnalyzer
        private let input: AsyncStream<AnalyzerInput>.Continuation
        private let converter: SpeechAudioConverter
        private let timeline = OSAllocatedUnfairLock(initialState: LiveTimeline())
        private var results: Task<Void, Never>?

        /// - Parameter natural: the format of the recorded audio.
        init(track: LiveTrack, locale: Locale, natural: AVAudioFormat, report: AsyncStream<LiveEvent>.Continuation,
             onError: @escaping @Sendable (Error) -> Void) async throws {
            let transcriber = AppleSpeech.transcriber(locale)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else {
                throw LiveEngineError("no audio format the speech recognizer accepts")
            }
            converter = SpeechAudioConverter(to: format)
            analyzer = SpeechAnalyzer(modules: [transcriber])
            let (sequence, input) = AsyncStream<AnalyzerInput>.makeStream()
            self.input = input
            let timeline = self.timeline
            results = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        guard result.isFinal else {
                            report.yield(.partial(track, text))
                            continue
                        }
                        let start = result.range.start.seconds
                        let end = result.range.end.seconds
                        guard start.isFinite, end.isFinite else { continue }
                        let (from, to) = timeline.withLock { ($0.recordedTime(start), $0.recordedTime(end)) }
                        report.yield(.final(track, text, start: from, end: to))
                    }
                } catch {
                    if !Task.isCancelled { onError(error) }
                }
            }
            try await analyzer.start(inputSequence: sequence)
        }

        /// Converts the buffer to the recognizer's format and queues it.
        func feed(_ buffer: AVAudioPCMBuffer, at time: Double) throws {
            let converted = try converter.convert(buffer)
            guard converted.frameLength > 0 else { return }
            timeline.withLock { $0.note(recorded: time, duration: Double(converted.frameLength) / converter.format.sampleRate) }
            input.yield(AnalyzerInput(buffer: converted))
        }

        /// Waits for the text of the audio queued so far.
        func finish() async throws {
            input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await results?.value
        }

        func cancel() async {
            input.finish()
            results?.cancel()
            await analyzer.cancelAndFinishNow()
        }
    }
}
