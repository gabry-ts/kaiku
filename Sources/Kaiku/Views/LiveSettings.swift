import KaikuCore
import PartitiUI
import SwiftUI

/// Live transcription in Settings > General. Only shown where an engine can run.
struct LiveSettingsSection: View {
    @AppStorage(Keys.liveEnabled) private var enabled = false
    @AppStorage(Keys.liveEngine) private var engine = LiveEngineKind.apple.rawValue
    @AppStorage(Keys.liveAfterCall) private var afterCall = LiveAfterCall.preview.rawValue
    @AppStorage(Keys.language) private var language = "auto"
    @State private var readiness: LiveReadiness?
    @State private var downloadError: String?
    /// True while this pane's own download runs, so a status check doesn't replace its progress.
    @State private var downloading = false

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
                SettingsRow(Text("Language"), subtitle: Text("The default for new calls, set above.")) {
                    ValueText(languageText)
                }
                statusRow
                if let downloadError {
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
        .onChange(of: enabled) { _, on in if on { Task { await refresh(); if case .needsDownload = readiness { await download() } } } }
    }

    @ViewBuilder private var statusRow: some View {
        switch readiness {
        case nil:
            GroupRow {
                HStack(spacing: PUI.Space.m) {
                    ProgressView().controlSize(.small)
                    Text("Checking the speech model…").font(PUI.Font.callout).foregroundStyle(.secondary)
                }
            }
        case .ready:
            GroupRow { StatusDot(kind: .ok, text: "Ready. The speech model is on this Mac.") }
        case .needsDownload(let what):
            GroupRow {
                HStack(spacing: PUI.Space.l) {
                    StatusDot(kind: .warning, text: "\(what) Live transcription starts once it is downloaded.")
                    Spacer(minLength: 0)
                    Button("Download") { Task { await download() } }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
            }
        case .downloading(let progress):
            GroupRow {
                HStack(spacing: PUI.Space.l) {
                    Text("Downloading the speech model… \(Int(progress * 100))%")
                        .font(PUI.Font.callout).monospacedDigit().foregroundStyle(.secondary)
                    ProgressView(value: min(max(progress, 0), 1)).controlSize(.small)
                }
            }
        case .unavailable(let why):
            GroupRow { StatusDot(kind: .error, text: why) }
        }
    }

    private func refresh() async {
        guard enabled else { return }
        if let preview = Self.previewReadiness {
            readiness = preview
            return
        }
        guard !downloading else { return }
        let state = await kind.readiness(language: AppSettings.normalizedLanguage(language))
        guard !downloading else { return }
        readiness = state
    }

    private func download() async {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        let kind = self.kind
        let language = AppSettings.normalizedLanguage(self.language)
        downloadError = nil
        readiness = .downloading(0)
        do {
            try await kind.download(language: language) { fraction in
                Task { @MainActor in
                    if downloading { readiness = .downloading(fraction) }
                }
            }
            readiness = await kind.readiness(language: language)
        } catch {
            downloadError = "Couldn't download the speech model: \(error.localizedDescription)"
            readiness = await kind.readiness(language: language)
        }
    }
}
