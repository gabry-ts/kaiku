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
                    if choice == .compatible {
                        CompatibleServerFields()
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
                    NavigationLink("AI summaries and chat") { AISettingsView() }
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

/// Address, model and optional key of an OpenAI-compatible transcription server.
struct CompatibleServerFields: View {
    @AppStorage(PhoneKeys.compatibleURL) private var url = ""
    @AppStorage(PhoneKeys.compatibleModel) private var model = ""
    @State private var checking = false
    @State private var result: String?

    var body: some View {
        TextField("Server address", text: $url, prompt: Text("http://192.168.1.10:8080/v1"))
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        TextField("Model", text: $model, prompt: Text("whisper-1"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        KeyRow(title: "API key (optional)", account: TranscriberChoice.compatibleKeyAccount, service: nil)
        Button("Check server") { check() }
            .disabled(checking || LocalLLM.customChatBase(url) == nil)
        if let result {
            Text(result).font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Asks for the server's model list: any answer means it is reachable.
    private func check() {
        guard let probe = LocalLLM.customModelsURL(url) else { return }
        checking = true
        result = nil
        Task {
            do {
                var request = URLRequest(url: probe, timeoutInterval: 8)
                let key = (Keychain.get(TranscriberChoice.compatibleKeyAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = "The server answered (HTTP \(status))."
            } catch {
                result = "Could not reach the server: \(error.localizedDescription)"
            }
            checking = false
        }
    }
}
