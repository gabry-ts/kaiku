import AVFoundation
import CoreMedia
import KaikuCore
import os
import Speech

/// Languages and models of the speech recognizer built into macOS 26.
@available(macOS 26, *)
enum AppleSpeech {
    /// The recognizer's locale for a language setting: "auto" is the system language.
    /// Nil when the recognizer doesn't know the language.
    static func locale(for language: String) async -> Locale? {
        let wanted = language == "auto" ? Locale.current : Locale(identifier: language)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) { return match }
        // A bare code like "en": take the variant of this Mac's region, else the most common one.
        guard let code = wanted.language.languageCode?.identifier else { return nil }
        let variants = await SpeechTranscriber.supportedLocales.filter { $0.language.languageCode?.identifier == code }
        let likelyRegion = Locale.Language(identifier: code).maximalIdentifier.split(separator: "-").last.map(String.init)
        return variants.first { $0.region == Locale.current.region }
            ?? variants.first { $0.region?.identifier == likelyRegion }
            ?? variants.first
    }

    /// Volatile results give the text as it is spoken; final ones replace them.
    static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// e.g. "Italian (Italy)".
    static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    static func name(ofLanguage language: String) -> String {
        language == "auto" ? "the system language" : (Locale.current.localizedString(forLanguageCode: language) ?? language)
    }

    /// Only asks the system what is installed; nothing is downloaded.
    static func readiness(language: String) async -> LiveReadiness {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("The system speech recognizer isn't available on this Mac.")
        }
        guard let locale = await locale(for: language) else {
            return .unavailable("The system speech recognizer doesn't support \(name(ofLanguage: language)).")
        }
        switch await AssetInventory.status(forModules: [transcriber(locale)]) {
        case .installed: return .ready
        case .downloading: return .downloading(0)
        case .supported: return .needsDownload("The speech model for \(name(locale)) isn't on this Mac yet.")
        case .unsupported: return .unavailable("The system speech recognizer doesn't support \(name(locale)).")
        @unknown default: return .unavailable("The system speech recognizer isn't available.")
        }
    }

    /// Downloads and installs the model of the language, reporting progress 0...1.
    static func download(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let locale = await locale(for: language) else {
            throw LiveEngineError("The system speech recognizer doesn't support \(name(ofLanguage: language)).")
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(locale)]) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            progress(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }
}

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
        guard await AssetInventory.status(forModules: [AppleSpeech.transcriber(locale)]) == .installed else {
            throw LiveEngineError("The speech model for \(AppleSpeech.name(locale)) isn't downloaded. Get it in Settings > General.")
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
        private let format: AVAudioFormat
        private var converter: AVAudioConverter?
        private let timeline = OSAllocatedUnfairLock(initialState: LiveTimeline())
        private var results: Task<Void, Never>?

        /// - Parameter natural: the format of the recorded audio.
        init(track: LiveTrack, locale: Locale, natural: AVAudioFormat, report: AsyncStream<LiveEvent>.Continuation,
             onError: @escaping @Sendable (Error) -> Void) async throws {
            let transcriber = AppleSpeech.transcriber(locale)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else {
                throw LiveEngineError("no audio format the speech recognizer accepts")
            }
            self.format = format
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
            let converted = try convert(buffer)
            guard converted.frameLength > 0 else { return }
            timeline.withLock { $0.note(recorded: time, duration: Double(converted.frameLength) / format.sampleRate) }
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

        private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
            if buffer.format == format { return buffer }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
                converter?.downmix = true
            }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw LiveEngineError("could not convert \(buffer.format) to \(format)")
            }
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
            if let error { throw error }
            return out
        }
    }
}
