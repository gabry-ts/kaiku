import SwiftUI
import KaikuCore

/// Whether the on-device speech model of the chosen language is installed, and a button to get it.
struct SpeechModelView: View {
    @State private var readiness: LiveReadiness?
    @State private var error: String?

    private var language: String { PhoneSettings.language }

    var body: some View {
        Form {
            Section {
                LabeledContent("Language", value: AppleSpeech.name(ofLanguage: language))
                switch readiness {
                case nil:
                    ProgressView()
                case .ready:
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .needsDownload(let text):
                    Text(text)
                    Button("Download model") { download() }
                case .downloading(let value):
                    ProgressView(value: value) { Text("Downloading…") }
                case .unavailable(let text):
                    Text(text).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("Speech recognition runs on this iPhone. The model is downloaded once for each language.")
            }
        }
        .navigationTitle("Speech model")
        .navigationBarTitleDisplayMode(.inline)
        .task { readiness = await AppleSpeech.readiness(language: language) }
    }

    private func download() {
        error = nil
        readiness = .downloading(0)
        let language = language
        Task {
            do {
                try await AppleSpeech.download(language: language) { value in
                    Task { @MainActor in readiness = .downloading(value) }
                }
            } catch {
                self.error = error.localizedDescription
            }
            readiness = await AppleSpeech.readiness(language: language)
        }
    }
}
