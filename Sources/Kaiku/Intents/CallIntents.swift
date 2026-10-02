import AppIntents
import KaikuCore
import UniformTypeIdentifiers

/// The call an intent works on: the one given, or the latest when none is.
@MainActor
private func resolve(_ entity: CallEntity?) throws -> (folder: RecordingFolder, meta: RecordingMeta) {
    if let entity {
        guard let folder = entity.folder, let meta = folder.loadMeta() else {
            throw KaikuIntentError(message: "This call is no longer in the library.")
        }
        return (folder, meta)
    }
    guard let call = CallSearch.last(base: AppSettings.baseFolder) else {
        throw KaikuIntentError(message: "There are no calls yet.")
    }
    return (call.folder, call.meta)
}

struct LastCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Call"
    static let description = IntentDescription("Returns the most recent call.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CallEntity> {
        guard let call = CallSearch.last(base: AppSettings.baseFolder) else {
            throw KaikuIntentError(message: "There are no calls yet.")
        }
        return .result(value: CallEntity(call))
    }
}

struct FindCallsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Calls"
    static let description = IntentDescription("Finds calls by text, tag or source, the latest first.")

    @Parameter(title: "Text", description: "Part of the title, a tag, the source or the transcript.")
    var text: String?

    @Parameter(title: "Tag")
    var tag: String?

    @Parameter(title: "Source", description: "The call app or website, such as Zoom.")
    var source: String?

    @Parameter(title: "Limit", default: 10, inclusiveRange: (1, 100))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find calls matching \(\.$text)") {
            \.$tag
            \.$source
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CallEntity]> {
        let found = CallSearch.find(base: AppSettings.baseFolder, text: text, tag: tag, source: source)
        return .result(value: found.prefix(limit).map(CallEntity.init))
    }
}

struct GetTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Transcript"
    static let description = IntentDescription("Returns the transcript of a call, the latest one when none is chosen.")

    @Parameter(title: "Call")
    var call: CallEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the transcript of \(\.$call)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let (folder, _) = try resolve(call)
        guard let data = try? Data(contentsOf: folder.transcriptURL) else {
            throw KaikuIntentError(message: "This call has no transcript yet.")
        }
        return .result(value: IntentFile(data: data, filename: RecordingFolder.transcriptName, type: .plainText))
    }
}

struct GetSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Summary"
    static let description = IntentDescription("Returns the summary of a call, the latest one when none is chosen.")

    @Parameter(title: "Call")
    var call: CallEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the summary of \(\.$call)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (folder, _) = try resolve(call)
        guard let summary = folder.summary else {
            throw KaikuIntentError(message: "This call has no summary yet.")
        }
        return .result(value: summary)
    }
}

struct TranscribeAgainIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Again"
    static let description = IntentDescription("Transcribes the audio of a call again, the latest one when none is chosen.")

    @Parameter(title: "Call")
    var call: CallEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$call) again")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (folder, _) = try resolve(call)
        let state = AppState.shared
        guard !state.isBusy(folder) else { throw KaikuIntentError(message: "This call is busy.") }
        guard FileManager.default.fileExists(atPath: folder.micURL.path)
            || FileManager.default.fileExists(atPath: folder.systemURL.path) else {
            throw KaikuIntentError(message: "The audio of this call was deleted.")
        }
        state.transcribe(folder: folder, provider: AppSettings.provider)
        return .result(dialog: "Transcription started.")
    }
}

struct GenerateSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Generate Summary"
    static let description = IntentDescription("Writes the summary of a call and returns it, the latest call when none is chosen.")

    @Parameter(title: "Call")
    var call: CallEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Generate the summary of \(\.$call)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (folder, _) = try resolve(call)
        let state = AppState.shared
        guard !state.isBusy(folder) else { throw KaikuIntentError(message: "This call is busy.") }
        do {
            try await state.generateSummary(folder)
        } catch {
            throw KaikuIntentError(message: error.localizedDescription)
        }
        return .result(value: folder.summary ?? "")
    }
}
