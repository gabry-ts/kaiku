import AVFoundation
import KaikuCore

/// The recorded track a piece of audio or text belongs to: `.me` is the microphone,
/// `.them` the system audio.
typealias LiveTrack = LiveSpeaker

/// What a live engine reports while it listens.
enum LiveEvent: Sendable {
    /// The text of the track's current line so far; it can still change.
    case partial(LiveTrack, String)
    /// A finished line, with its place in the recording in seconds.
    case final(LiveTrack, String, start: Double, end: Double)
    /// The engine gave up. Nothing more is reported after this.
    case failed(String)
}

/// A speech-to-text backend that transcribes while the call is being recorded.
/// Adding an engine means one type conforming to this and one case in `LiveEngineKind`.
protocol LiveEngine: AnyObject, Sendable {
    /// Everything the engine reports. Ends after `stop()` or a failure.
    var events: AsyncStream<LiveEvent> { get }

    /// Gets ready to transcribe. Throws when the engine can't run (language not supported,
    /// model missing, no network); it never downloads anything or asks for permissions.
    /// - Parameter language: "auto" or an ISO code, as in the recording's settings.
    func start(language: String) async throws

    /// Takes audio of one track. Called on the audio thread, also before `start` has
    /// returned: it must only queue the buffer and return. The buffer is a copy the
    /// engine may keep.
    /// - Parameter time: where the buffer starts in the recording, in seconds.
    func feed(_ buffer: AVAudioPCMBuffer, track: LiveTrack, at time: Double)

    /// Transcribes what was queued, reports the last lines and ends `events`.
    func stop() async
}

struct LiveEngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Whether an engine can run for a language, shown in Settings.
enum LiveReadiness: Equatable {
    case ready
    /// A model has to be downloaded first; the text says which.
    case needsDownload(String)
    /// Downloading the model, 0...1.
    case downloading(Double)
    /// The engine can't be used, with the reason.
    case unavailable(String)
}

/// The live engines this version ships. The settings picker lists `available`.
enum LiveEngineKind: String, CaseIterable, Identifiable {
    /// The speech recognizer built into macOS, on device.
    case apple
    /// whisper.cpp on device, in chunks of a few seconds.
    case whisper
    /// OpenAI's Realtime API, streamed to the cloud.
    case openAI = "openai"
    /// ElevenLabs Scribe realtime, streamed to the cloud.
    case elevenLabs = "elevenlabs"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple (on device)"
        case .whisper: return "whisper.cpp (on device)"
        case .openAI: return "OpenAI Realtime"
        case .elevenLabs: return "ElevenLabs Scribe Realtime"
        }
    }

    /// What the engine does with the audio, for the settings footer.
    var privacyNote: String {
        switch self {
        case .apple, .whisper: return "Audio is transcribed on this Mac and never leaves it."
        case .openAI: return "Audio is sent to OpenAI while you record."
        case .elevenLabs: return "Audio is sent to ElevenLabs while you record."
        }
    }

    /// What choosing the engine costs, shown under the picker. Nil when there is nothing to say.
    var notice: String? {
        switch self {
        case .apple:
            return nil
        case .whisper:
            return "whisper.cpp transcribes about ten seconds at a time: the text shows some ten seconds after it is said. whisper-server keeps the model loaded during the call; a small model uses far less battery."
        case .openAI, .elevenLabs:
            let name = keyProvider == .openAI ? "OpenAI" : "ElevenLabs"
            return "During the call the audio of both tracks, your microphone and the other people, is sent to \(name) as two streams. \(name) bills both to your account."
        }
    }

    /// The status line when the engine can run.
    var readyText: String {
        switch self {
        case .apple: return "Ready. The speech model is on this Mac."
        case .whisper: return "Ready. whisper-server and its model are on this Mac."
        case .openAI: return "Ready. Uses your OpenAI API key."
        case .elevenLabs: return "Ready. Uses your ElevenLabs API key."
        }
    }

    /// The transcription provider whose API key a cloud engine uses, nil on device.
    var keyProvider: ProviderKind? {
        switch self {
        case .apple, .whisper: return nil
        case .openAI: return .openAI
        case .elevenLabs: return .elevenLabs
        }
    }

    /// What to do when the key of a cloud engine is missing.
    private var keyHint: String {
        "Add an \(self == .openAI ? "OpenAI" : "ElevenLabs") API key in Settings > Transcription."
    }

    /// The engines that can run on this version of macOS.
    static var available: [LiveEngineKind] {
        allCases.filter(\.isAvailable)
    }

    /// The live transcript itself needs macOS 26, whatever the engine.
    var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// A new engine for one recording, or nil when it can't run on this Mac.
    func make() -> LiveEngine? {
        switch self {
        case .apple:
            if #available(macOS 26, *) { return AppleLiveEngine() }
            return nil
        case .whisper:
            return WhisperLiveEngine()
        case .openAI:
            return StreamingLiveEngine(api: .openAI, key: Keychain.apiKey(for: .openAI), keyHint: keyHint)
        case .elevenLabs:
            return StreamingLiveEngine(api: .elevenLabs, key: Keychain.apiKey(for: .elevenLabs), keyHint: keyHint)
        }
    }

    /// Whether the engine is ready to transcribe `language` ("auto" or an ISO code).
    func readiness(language: String) async -> LiveReadiness {
        switch self {
        case .apple:
            if #available(macOS 26, *) { return await AppleSpeech.readiness(language: language) }
            return .unavailable("Needs macOS 26 or later.")
        case .whisper:
            return WhisperLiveEngine.readiness
        case .openAI, .elevenLabs:
            return keyProvider.flatMap(Keychain.apiKey(for:)) == nil ? .unavailable(keyHint) : .ready
        }
    }

    /// Downloads what `readiness` said is missing. Only ever called from Settings.
    func download(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch self {
        case .apple:
            guard #available(macOS 26, *) else { throw LiveEngineError("Needs macOS 26 or later.") }
            try await AppleSpeech.download(language: language, progress: progress)
        case .whisper:
            throw LiveEngineError("whisper.cpp models are downloaded in Settings > Transcription.")
        case .openAI, .elevenLabs:
            throw LiveEngineError("There is nothing to download for \(displayName).")
        }
    }
}

/// Live transcription as a feature: it exists only where at least one engine can run.
enum LiveTranscription {
    static var isSupported: Bool { !LiveEngineKind.available.isEmpty }
}

/// What happens to the live text when the call ends.
enum LiveAfterCall: String, CaseIterable, Identifiable {
    /// The live text is thrown away and the call is transcribed as usual.
    case preview
    /// The live text becomes the transcript and the usual transcription is skipped.
    case transcript
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preview: return "Preview only"
        case .transcript: return "Use as the transcript"
        }
    }
}
