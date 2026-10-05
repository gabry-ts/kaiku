import SwiftUI
import KaikuCore

/// API keys, kept in the Keychain of this iPhone.
struct AccountsView: View {
    @AppStorage(PhoneKeys.alibabaRegion) private var region = AlibabaRegion.singapore.rawValue

    var body: some View {
        Form {
            Section("Transcription and AI") {
                KeyRow(title: "OpenAI", account: ProviderKind.openAI.rawValue, service: .openAI)
                KeyRow(title: "Groq", account: ProviderKind.groq.rawValue, service: .groq)
            }
            Section("Transcription") {
                KeyRow(title: "ElevenLabs", account: ProviderKind.elevenLabs.rawValue, service: .elevenLabs)
                KeyRow(title: "Alibaba Cloud", account: ProviderKind.alibaba.rawValue, service: nil)
                Picker("Alibaba region", selection: $region) {
                    ForEach(AlibabaRegion.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            Section("AI") {
                KeyRow(title: "Anthropic", account: SummaryProviderKind.anthropic.keyAccount, service: .anthropic)
                KeyRow(title: "OpenRouter", account: SummaryProviderKind.openRouter.keyAccount, service: .openRouter)
            }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One API key: saved as it is typed, with a button that checks it with the service.
struct KeyRow: View {
    let title: String
    let account: String
    let service: KeyCheck.Service?

    @State private var key = ""
    @State private var loaded = false
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(title, text: $key)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let service, !trimmed.isEmpty {
                HStack {
                    Button("Test key") { test(service) }
                        .buttonStyle(.borderless)
                        .disabled(testing)
                    if let result {
                        Text(result.message)
                            .font(.footnote)
                            .foregroundStyle(result.ok ? Color.green : Color.red)
                    }
                }
            }
            if let error = Keychain.errors[account] {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .onAppear {
            key = Keychain.get(account) ?? ""
            loaded = true
        }
        .onChange(of: key) {
            guard loaded else { return }
            result = nil
            Keychain.set(trimmed, for: account)
        }
    }

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func test(_ service: KeyCheck.Service) {
        testing = true
        let value = trimmed
        Task {
            let outcome = await KeyCheck.test(service, key: value, name: title)
            result = outcome
            testing = false
        }
    }
}
