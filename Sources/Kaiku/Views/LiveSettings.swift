import KaikuCore
import PartitiUI
import SwiftUI

/// Settings > Transcription > Live Transcription: the transcript while recording and its engine.
/// Shown switched off, with the reason, where no engine can run.
struct LiveSettings: View {
    @AppStorage(Keys.liveEnabled) private var enabled = false
    @AppStorage(Keys.liveEngine) private var engine = LiveEngineKind.apple.rawValue
    @AppStorage(Keys.liveAfterCall) private var afterCall = LiveAfterCall.preview.rawValue
    @AppStorage(Keys.language) private var language = "auto"
    @AppStorage(Keys.liveWhisperModel) private var liveWhisperModel = ""
    @StateObject private var model = SpeechModelStatus()

    /// Snapshot rendering only: shown instead of asking the system.
    static var previewReadiness: LiveReadiness?

    private var kind: LiveEngineKind { AppSettings.liveEngine ?? .apple }
    private var footer: String {
        "Shows in the panel and in a floating window. \(kind.privacyNote)"
    }

    private var afterCallDetail: String {
        LiveAfterCall(rawValue: afterCall) == .transcript
            ? "Keeps the live text. You can still transcribe the call again."
            : "The call is transcribed as usual when it ends."
    }

    var body: some View {
        SettingsGroup(Text("Live Transcription"), footer: Text(footer)) {
            if !LiveTranscription.isSupported {
                SettingsRow(Text("Show the transcript while recording"), subtitle: Text("Live transcription needs macOS 26.")) {
                    Toggle("Show the transcript while recording", isOn: .constant(false))
                        .toggleStyle(PUISwitchStyle(showsLabel: false))
                        .disabled(true)
                }
            } else {
                SwitchRow("Show the transcript while recording", isOn: $enabled)
            }
            if enabled && LiveTranscription.isSupported {
                SettingsRow("Engine") {
                    Picker("Engine", selection: $engine) {
                        ForEach(LiveEngineKind.available) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let notice = kind.notice {
                    GroupRow {
                        if let provider = kind.keyProvider {
                            HStack {
                                StatusDot(kind: .warning, text: "No \(provider.displayName) key yet")
                                Spacer(minLength: PUI.Space.m)
                                if let service = AccountService.of(provider) { SetUpButton(service: service) }
                            }
                        } else {
                            Text(notice).font(PUI.Font.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if kind == .whisper {
                    SettingsRow(Text("Live model"), subtitle: Text("A light model is enough live and saves battery. [Download models](kaiku-settings:model)")) {
                        Picker("Live model", selection: $liveWhisperModel) {
                            Text("Automatic (Small or Base)").tag("")
                            ForEach(WhisperModel.catalog.filter(\.isInstalled)) { m in
                                Text(m.name).tag(m.localURL.path)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                SpeechModelStatusRow(readiness: model.readiness, readyText: kind.readyText,
                                     downloadNote: "Live transcription starts once it is downloaded.") {
                    Task { await download() }
                }
                if let downloadError = model.downloadError {
                    GroupRow { StatusDot(kind: .error, text: downloadError) }
                }
                SettingsRow(Text("After the call"), subtitle: Text(afterCallDetail)) {
                    SegmentedPill(LiveAfterCall.allCases.map { (value: $0.rawValue, title: $0.displayName) }, selection: $afterCall)
                        .fixedSize()
                }
                SettingsRow(Text("Live Assist"), subtitle: Text("Summary and questions during the call")) {
                    Button("Open in AI") { WindowManager.shared.showSettings(.ai, anchor: "liveAssist") }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
            }
        }
        .settingsAnchor("live")
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "kaiku-settings" else { return .systemAction }
            WindowManager.shared.showSettings(.transcription, anchor: url.absoluteString.replacingOccurrences(of: "kaiku-settings:", with: ""))
            return .handled
        })
        .task(id: "\(enabled) \(engine) \(language) \(liveWhisperModel)") { await refresh() }
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
