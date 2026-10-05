import AppIntents

/// What the app does when an intent asks it to control the recording.
@MainActor
protocol RecordingIntentHandler: AnyObject {
    func start() async
    var errorMessage: String? { get }
    var isActive: Bool { get }
    func addBookmark()
    func pause()
    func resume()
    func stop() async
}

/// Set by the app at launch. It is nil in the widget process, where the intents must not run.
enum RecordingIntentBridge {
    @MainActor static var handler: RecordingIntentHandler?

    @MainActor static func require() throws -> RecordingIntentHandler {
        guard let handler else { throw RecordingIntentError.appNotRunning }
        return handler
    }
}

enum RecordingIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotRunning
    case notStarted(String?)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotRunning: return "Open Kaiku and try again."
        case .notStarted(let reason): return "\(reason ?? "Recording could not start.")"
        }
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    @MainActor func perform() async throws -> some IntentResult {
        try await RecordingIntentBridge.require().stop()
        return .result()
    }
}

struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Recording"
    static let isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        try RecordingIntentBridge.require().pause()
        return .result()
    }
}

struct ResumeRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume Recording"
    static let isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        try RecordingIntentBridge.require().resume()
        return .result()
    }
}

/// Starts recording. The Live Activity starts together with the recording, before this returns.
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts recording a meeting with the microphone.")

    @MainActor func perform() async throws -> some IntentResult {
        let handler = try RecordingIntentBridge.require()
        if !handler.isActive { await handler.start() }
        guard handler.isActive else { throw RecordingIntentError.notStarted(handler.errorMessage) }
        return .result()
    }
}

/// Backs the Control Center toggle: on starts a recording, off stops it.
struct ToggleRecordingIntent: SetValueIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record"

    @Parameter(title: "Recording") var value: Bool

    @MainActor func perform() async throws -> some IntentResult {
        let handler = try RecordingIntentBridge.require()
        if value, !handler.isActive {
            await handler.start()
            guard handler.isActive else { throw RecordingIntentError.notStarted(handler.errorMessage) }
        } else if !value, handler.isActive {
            await handler.stop()
        }
        return .result()
    }
}

struct AddBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Bookmark"
    static let description = IntentDescription("Marks the current moment of the recording.")

    @MainActor func perform() async throws -> some IntentResult {
        try RecordingIntentBridge.require().addBookmark()
        return .result()
    }
}
