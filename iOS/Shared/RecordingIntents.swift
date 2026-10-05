import AppIntents

/// What the app does when an intent asks it to control the recording.
@MainActor
protocol RecordingIntentHandler: AnyObject {
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

    var localizedStringResource: LocalizedStringResource { "Open Kaiku and try again." }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let isDiscoverable = false

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
