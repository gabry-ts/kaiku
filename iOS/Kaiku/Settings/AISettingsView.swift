import SwiftUI
import KaikuCore

/// The providers that write summaries and answer chat questions.
struct AISettingsView: View {
    @AppStorage(PhoneKeys.summaryEnabled) private var summaryEnabled = false
    @AppStorage(PhoneKeys.summaryProvider) private var summaryProvider = SummaryProviderKind.openAI.rawValue
    @AppStorage(PhoneKeys.chatProvider) private var chatProvider = ""

    private var summaryKind: SummaryProviderKind { SummaryProviderKind(rawValue: summaryProvider) ?? .openAI }
    private var chatKind: SummaryProviderKind { SummaryProviderKind(rawValue: chatProvider) ?? summaryKind }

    var body: some View {
        Form {
            Section {
                Toggle("Write a summary after transcribing", isOn: $summaryEnabled)
                providerPicker($summaryProvider)
                ProviderFields(kind: summaryKind, modelKey: PhoneKeys.summaryModel(summaryKind))
            } header: {
                Text("Summaries")
            } footer: {
                Text("The transcript is sent to the provider. Keys are added in Accounts.")
            }
            Section("Chat") {
                providerPicker(Binding(get: { chatKind.rawValue }, set: { chatProvider = $0 }))
                ProviderFields(kind: chatKind, modelKey: PhoneKeys.chatModel(chatKind))
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func providerPicker(_ selection: Binding<String>) -> some View {
        Picker("Provider", selection: selection) {
            ForEach(SummaryProviderKind.phoneProviders) { Text($0.displayName).tag($0.rawValue) }
        }
    }
}

/// Model, server address and key of one provider.
private struct ProviderFields: View {
    let kind: SummaryProviderKind
    let modelKey: String
    @AppStorage private var model: String
    @AppStorage private var address: String

    init(kind: SummaryProviderKind, modelKey: String) {
        self.kind = kind
        self.modelKey = modelKey
        _model = AppStorage(wrappedValue: "", modelKey)
        _address = AppStorage(wrappedValue: "", PhoneKeys.baseURL(kind))
    }

    var body: some View {
        TextField("Model", text: $model, prompt: Text(kind.modelPlaceholder))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        if kind.isLocal {
            TextField("Server address", text: $address, prompt: Text(kind.baseURLPlaceholder))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if kind == .custom {
                KeyRow(title: "API key (optional)", account: kind.keyAccount, service: nil)
            }
        }
        if let hint = kind.modelHint {
            Text(hint).font(.footnote).foregroundStyle(.secondary)
        }
        if let problem = kind.problem {
            Text(problem).font(.footnote).foregroundStyle(.orange)
        }
    }
}
