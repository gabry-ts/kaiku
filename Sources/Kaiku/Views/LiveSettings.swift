import KaikuCore
import PartitiUI
import SwiftUI

/// Live transcription in Settings > General. Only shown where an engine can run.
struct LiveSettingsSection: View {
    @AppStorage(Keys.liveEnabled) private var enabled = false
    @AppStorage(Keys.liveEngine) private var engine = LiveEngineKind.apple.rawValue
    @AppStorage(Keys.liveAfterCall) private var afterCall = LiveAfterCall.preview.rawValue
    @AppStorage(Keys.language) private var language = "auto"
    @AppStorage(Keys.liveAssistEnabled) private var assist = false
    @AppStorage(Keys.summaryProvider) private var summaryProvider = SummaryProviderKind.openAI.rawValue
    @AppStorage(Keys.liveProvider) private var liveProvider = ""
    @State private var summaryModel = ""
    @State private var askModel = ""
    @StateObject private var access = ProviderAccess()
    @StateObject private var model = SpeechModelStatus()

    /// Snapshot rendering only: shown instead of asking the system.
    static var previewReadiness: LiveReadiness?

    private var kind: LiveEngineKind { AppSettings.liveEngine ?? .apple }
    private var assistKind: SummaryProviderKind {
        SummaryProviderKind(rawValue: liveProvider) ?? SummaryProviderKind(rawValue: summaryProvider) ?? .openAI
    }

    private var footer: String {
        var text = "What is being said shows in the popover and in a floating window, as Me and Them. \(kind.privacyNote) Preview only transcribes the call as usual when it ends. Use as the transcript keeps the live text instead; you can still transcribe the call again from the library."
        if assist {
            text += " Summary and Ask send the transcript to the provider chosen here while you talk, even when the engine runs on this Mac. The live summary is saved as live-summary.md in the call folder."
        }
        return text
    }

    var body: some View {
        SettingsGroup(Text("Live Transcription"), footer: Text(footer)) {
            SwitchRow("Show the transcript while recording", isOn: $enabled)
            if enabled {
                SettingsRow("Engine") {
                    Picker("Engine", selection: $engine) {
                        ForEach(LiveEngineKind.available) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let notice = kind.notice {
                    GroupRow {
                        if kind.keyProvider == nil {
                            Text(notice).font(PUI.Font.callout).foregroundStyle(.secondary)
                        } else {
                            StatusDot(kind: .warning, text: notice)
                        }
                    }
                }
                SettingsRow(Text("Language"), subtitle: Text("The default for new calls, set above.")) {
                    ValueText(LanguagePicker.recognizerName(language))
                }
                SpeechModelStatusRow(readiness: model.readiness, readyText: kind.readyText,
                                     downloadNote: "Live transcription starts once it is downloaded.") {
                    Task { await download() }
                }
                if let downloadError = model.downloadError {
                    GroupRow { StatusDot(kind: .error, text: downloadError) }
                }
                SettingsRow("After the call") {
                    Picker("After the call", selection: $afterCall) {
                        ForEach(LiveAfterCall.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SwitchRow("Summarize and answer questions during the call", isOn: $assist)
                if assist {
                    SettingsRow("Provider") {
                        Picker("Provider", selection: Binding(get: { assistKind.rawValue }, set: { liveProvider = $0 })) {
                            ForEach(SummaryProviderKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    ModelField(kind: assistKind, text: $summaryModel, title: "Summary model",
                               subtitle: "Updates the summary every minute or so.")
                    ModelField(kind: assistKind, text: $askModel, title: "Ask model",
                               subtitle: assistKind.cli == nil
                                   ? "Answers your questions; a fast one keeps them quick."
                                   : "Answers your questions. A command-line tool starts for each one, so answers take longer.")
                    ProviderAccessRows(access: access,
                                       modelMissing: assistKind.requiresModel && (summaryModel.isEmpty || askModel.isEmpty))
                }
            }
        }
        .onAppear(perform: loadModels)
        .onChange(of: summaryProvider) { _, _ in loadModels() }
        .onChange(of: liveProvider) { _, _ in loadModels() }
        .onChange(of: summaryModel) { _, v in
            AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.liveSummaryModel(assistKind))
        }
        .onChange(of: askModel) { _, v in
            AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.liveAskModel(assistKind))
        }
        .task(id: "\(enabled) \(engine) \(language)") { await refresh() }
        // The model is fetched when the feature is switched on, never during a call.
        .onChange(of: enabled) { _, on in if on { Task { await refresh(); if case .needsDownload = model.readiness { await download() } } } }
    }

    private func loadModels() {
        summaryModel = AppSettings.liveSummaryModel(for: assistKind)
        askModel = AppSettings.liveAskModel(for: assistKind)
        access.load(assistKind)
    }

    private func refresh() async {
        guard enabled else { return }
        if let preview = Self.previewReadiness {
            model.show(preview)
            return
        }
        let kind = self.kind
        let language = AppSettings.normalizedLanguage(self.language)
        await model.refresh { await kind.readiness(language: language) }
    }

    private func download() async {
        let kind = self.kind
        let language = AppSettings.normalizedLanguage(self.language)
        await model.download({ try await kind.download(language: language, progress: $0) },
                             check: { await kind.readiness(language: language) })
    }
}
