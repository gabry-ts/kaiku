import AppIntents
import KaikuCore

/// Why an intent could not do what it was asked.
struct KaikuIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts recording a call, with an optional title.")

    @Parameter(title: "Title")
    var callTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start recording \(\.$callTitle)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = AppState.shared
        guard !state.isRecording else { throw KaikuIntentError(message: "A recording is already running.") }
        await state.startRecording(title: callTitle ?? "", language: AppSettings.language)
        guard state.isRecording else { throw KaikuIntentError(message: "Kaiku could not start recording.") }
        return .result(dialog: "Recording started.")
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the current recording and transcribes it.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = AppState.shared
        guard state.isRecording else { throw KaikuIntentError(message: "No recording is running.") }
        state.stopRecording()
        return .result(dialog: "Recording stopped.")
    }
}

struct TogglePauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Recording"
    static let description = IntentDescription("Pauses the current recording, or resumes it when it is paused.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = AppState.shared
        guard state.canPause else { throw KaikuIntentError(message: "No recording is running.") }
        state.togglePause()
        return .result(dialog: state.isPaused ? "Recording paused." : "Recording resumed.")
    }
}

struct AddBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Bookmark"
    static let description = IntentDescription("Marks the current moment of the recording.")

    @Parameter(title: "Label")
    var label: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add a bookmark \(\.$label)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AppState.shared.addBookmark(label: label ?? "") != nil else {
            throw KaikuIntentError(message: "No recording is running.")
        }
        return .result(dialog: "Bookmark added.")
    }
}

struct ToggleMicrophonesIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Microphones"
    static let description = IntentDescription("Mutes all microphones, or unmutes them when they are muted.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MicMuter.shared.toggle()
        return .result(dialog: MicMuter.shared.isMuted ? "Microphones muted." : "Microphones unmuted.")
    }
}
