import AVFoundation
import KaikuCore

/// The live transcription of the recording in progress. Owns the engine, takes the audio
/// the track writers hand over and publishes the text. It only ever reads a copy of the
/// audio: whatever happens here, the recording and the transcription after it go on.
@MainActor
final class LiveSession: ObservableObject {
    @Published private(set) var transcript = LiveTranscript()
    /// True from the start of a recording with live transcription on, until it stops or fails.
    @Published private(set) var isRunning = false
    /// Why the live transcription stopped early, shown in the recording card.
    @Published private(set) var notice: String?
    /// The Summary and Ask tabs of the live window.
    let assistant = LiveAssistant()

    private var engine: LiveEngine?
    private var listener: Task<Void, Never>?
    /// Recording time, for lines the engine reports without one.
    private var clock: () -> Double = { 0 }

    /// True when there is something to show for the current recording.
    var isVisible: Bool { isRunning || !transcript.isEmpty }

    /// The closure the track writers call with every buffer they wrote (audio thread).
    /// It only queues the copy in the engine.
    nonisolated static func tap(into engine: LiveEngine) -> @Sendable (AVAudioPCMBuffer, Double, LiveTrack) -> Void {
        { buffer, time, track in engine.feed(buffer, track: track, at: time) }
    }

    /// Starts listening with `engine`. Returns at once: the engine gets ready in the
    /// background and queues the audio it receives meanwhile.
    func start(_ engine: LiveEngine, language: String, clock: @escaping () -> Double) {
        cancel()
        self.engine = engine
        self.clock = clock
        transcript = LiveTranscript()
        notice = nil
        isRunning = true
        assistant.start { [weak self] in self?.transcript ?? LiveTranscript() }
        listener = Task { [weak self] in
            for await event in engine.events {
                guard let self, self.engine === engine else { return }
                self.handle(event)
            }
        }
        Task { [weak self] in
            do {
                try await engine.start(language: language)
            } catch {
                guard let self, self.engine === engine else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    /// How long `finish` waits for the engine's last words, in seconds.
    private static let stopTimeout: Double = 8

    /// What a finished session heard.
    struct Outcome {
        let transcript: LiveTranscript
        /// False when the engine failed or didn't finish in time, so text is missing.
        let complete: Bool
        /// The live summary as Markdown, if one was written.
        var summary: String?
    }

    /// Stops with the recording and returns everything heard, the last words included.
    /// Never waits longer than a few seconds for the engine.
    func finish() async -> Outcome {
        guard let engine, isRunning else {
            let heard = transcript
            let summary = assistant.summaryMarkdown
            reset()
            return Outcome(transcript: heard, complete: false, summary: summary)
        }
        let listener = self.listener
        let stopping = Task { await engine.stop() }
        let began = Date()
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.stopTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            listener?.cancel()
            stopping.cancel()
        }
        await listener?.value
        timeout.cancel()
        // A failure reported while stopping has already ended the session.
        let complete = isRunning && Date().timeIntervalSince(began) < Self.stopTimeout
        transcript.finalizePartials()
        let heard = transcript
        let summary = assistant.summaryMarkdown
        reset()
        return Outcome(transcript: heard, complete: complete, summary: summary)
    }

    /// Stops without keeping anything (recording discarded, or the app is quitting).
    func cancel() {
        if let engine { Task { await engine.stop() } }
        reset()
    }

    private func reset() {
        listener?.cancel()
        listener = nil
        engine = nil
        isRunning = false
        transcript = LiveTranscript()
        notice = nil
        assistant.reset()
    }

    private func handle(_ event: LiveEvent) {
        switch event {
        case .partial(let track, let text):
            transcript.setPartial(text, speaker: track, at: clock())
        case .final(let track, let text, let start, let end):
            transcript.addFinal(text, speaker: track, start: start, end: end)
        case .failed(let message):
            fail(message)
        }
    }

    /// Ends the live session only; what was heard so far stays on screen.
    private func fail(_ message: String) {
        guard isRunning else { return }
        Log.transcription.error("Live transcription stopped: \(message, privacy: .public)")
        let engine = self.engine
        self.engine = nil
        listener?.cancel()
        listener = nil
        isRunning = false
        transcript.finalizePartials()
        notice = message
        if let engine { Task { await engine.stop() } }
    }

    /// Snapshot rendering only.
    func setPreview(_ transcript: LiveTranscript, running: Bool = true, notice: String? = nil) {
        reset()
        self.transcript = transcript
        self.isRunning = running
        self.notice = notice
    }
}
