import SwiftUI
import KaikuCore

struct SettingsView: View {
    @AppStorage(PhoneKeys.transcriber) private var transcriber = TranscriberChoice.apple.rawValue
    @AppStorage(PhoneKeys.language) private var language = ""
    @AppStorage(PhoneKeys.meLabel) private var meLabel = ""
    @AppStorage(PhoneKeys.othersLabel) private var othersLabel = ""

    private var choice: TranscriberChoice { TranscriberChoice(rawValue: transcriber) ?? .apple }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Engine", selection: $transcriber) {
                        ForEach(TranscriberChoice.all) { Text($0.displayName).tag($0.rawValue) }
                    }
                    if choice == .apple {
                        NavigationLink("Speech model") { SpeechModelView() }
                    }
                    if choice == .whisper {
                        NavigationLink("Whisper models") { WhisperModelsView() }
                    }
                    if case .cloud(let kind) = choice {
                        ModelField(kind: kind)
                    }
                    TextField("Language", text: $language, prompt: Text("auto"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Language is auto or an ISO code such as en or it. Apple speech uses the language of the iPhone when it is auto.")
                }
                Section {
                    TextField("Your label", text: $meLabel, prompt: Text("Me"))
                    TextField("Other people", text: $othersLabel, prompt: Text("Others"))
                } header: {
                    Text("Speaker names")
                }
                Section {
                    NavigationLink("Accounts") { AccountsView() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// The model sent to a cloud transcription service, with the usual ones to pick from.
struct ModelField: View {
    let kind: ProviderKind
    @AppStorage private var model: String

    init(kind: ProviderKind) {
        self.kind = kind
        _model = AppStorage(wrappedValue: "", PhoneKeys.model(kind))
    }

    var body: some View {
        TextField("Model", text: $model, prompt: Text(kind.defaultModel))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        if !kind.modelPresets.isEmpty {
            Picker("Suggested", selection: $model) {
                Text("Default").tag("")
                ForEach(kind.modelPresets, id: \.self) { Text($0).tag($0) }
            }
        }
    }
}
