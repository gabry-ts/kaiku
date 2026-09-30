import KaikuCore
import PartitiUI
import SwiftUI

/// Live transcription in Settings > General. Only shown where an engine can run.
struct LiveSettingsSection: View {
    @AppStorage(Keys.liveEnabled) private var enabled = false
    @AppStorage(Keys.liveEngine) private var engine = LiveEngineKind.apple.rawValue
    @AppStorage(Keys.liveAfterCall) private var afterCall = LiveAfterCall.preview.rawValue
    @AppStorage(Keys.language) private var language = "auto"
    @StateObject private var model = SpeechModelStatus()

    /// Snapshot rendering only: shown instead of asking the system.
    static var previewReadiness: LiveReadiness?

    private var kind: LiveEngineKind { AppSettings.liveEngine ?? .apple }

    private var footer: String {
        "What is being said shows in the popover and in a floating window, as Me and Them. \(kind.privacyNote) Preview only transcribes the call as usual when it ends. Use as the transcript keeps the live text instead; you can still transcribe the call again from the library."
    }

    private var languageText: String {
        guard AppSettings.normalizedLanguage(language) == "auto" else { return LanguagePicker.displayName(language) }
        let system = Locale.current.language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }
        return system.map { "Your Mac's language (\($0))" } ?? "Your Mac's language"
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
                    ValueText(languageText)
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
            }
        }
        .task(id: "\(enabled) \(engine) \(language)") { await refresh() }
        // The model is fetched when the feature is switched on, never during a call.
        .onChange(of: enabled) { _, on in if on { Task { await refresh(); if case .needsDownload = model.readiness { await download() } } } }
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
