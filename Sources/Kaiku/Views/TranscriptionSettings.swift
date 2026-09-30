import PartitiUI
import SwiftUI
import KaikuCore

struct TranscriptionSettings: View {
    @AppStorage(Keys.provider) private var provider = ProviderKind.whisperCpp.rawValue
    /// Bumped to re-evaluate readiness after keys or models change.
    @State private var refresh = 0
    @AppStorage(Keys.language) private var language = "auto"
    /// The system recognizer's speech model for the default language.
    @StateObject private var speech = SpeechModelStatus()

    /// Snapshot rendering only: shown instead of asking the system.
    static var previewSpeechReadiness: LiveReadiness?

    private var kind: ProviderKind { AppSettings.provider(saved: provider) }

    var body: some View {
        KaikuPane(pane: .transcription, subtitle: "Who turns your calls into text, and with which model.") {
            SettingsGroup("Provider", footer: "Your microphone and the call audio are transcribed separately, so the transcript knows who said what.") {
                ForEach(ProviderKind.available) { p in
                    ProviderRow(kind: p, selected: p == kind, status: status(of: p), refresh: refresh) {
                        withAnimation(.snappy) { provider = p.rawValue }
                    }
                }
            }

            if kind == .whisperCpp {
                WhisperSettings(onChange: { refresh += 1 })
            } else if kind == .apple {
                AppleSettings(speech: speech, language: language) { Task { await downloadSpeechModel() } }
            } else {
                CloudProviderSettings(kind: kind, onChange: { refresh += 1 }).id(kind)
            }

            ProviderTestSection(kind: kind).id("test-\(kind.rawValue)")

            SilenceTrimSection()
            PriceSection(kind: kind).id("price-\(kind.rawValue)")
            SummarySettings()
        }
        .task(id: language) { await refreshSpeechModel() }
    }

    /// A provider's state in the list. Apple's is the state of its speech model.
    private func status(of provider: ProviderKind) -> (ready: Bool, text: String) {
        guard provider == .apple else {
            let readiness = provider.readiness
            return (readiness == .ready, readiness.text)
        }
        switch speech.readiness {
        case nil: return (false, "Checking…")
        case .ready: return (true, ProviderReadiness.ready.text)
        case .needsDownload: return (false, ProviderReadiness.needsModel.text)
        case .downloading: return (false, "Downloading…")
        case .unavailable: return (false, ProviderReadiness.unavailable.text)
        }
    }

    /// Only asks the system what is installed; nothing is downloaded.
    private func refreshSpeechModel() async {
        guard ProviderKind.apple.isAvailable else { return }
        if let preview = Self.previewSpeechReadiness {
            speech.show(preview)
            return
        }
        let language = AppSettings.normalizedLanguage(self.language)
        await speech.refresh { await LiveEngineKind.apple.readiness(language: language) }
    }

    private func downloadSpeechModel() async {
        let language = AppSettings.normalizedLanguage(self.language)
        await speech.download({ try await LiveEngineKind.apple.download(language: language, progress: $0) },
                              check: { await LiveEngineKind.apple.readiness(language: language) })
    }
}

private struct ProviderRow: View {
    let kind: ProviderKind
    let selected: Bool
    let status: (ready: Bool, text: String)
    let refresh: Int
    let select: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        Button(action: select) {
            HStack(spacing: PUI.Space.m + 2) {
                IconTile(kind.symbol, color: kind.tileColor, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName).font(PUI.Font.body).foregroundStyle(ink.primary)
                    Text(kind.tagline).font(PUI.Font.caption).foregroundStyle(ink.secondary)
                }
                Spacer(minLength: PUI.Space.l)
                HStack(spacing: PUI.Space.xs) {
                    Circle().fill(status.ready ? ink.green : ink.tertiary).frame(width: 6, height: 6)
                    Text(status.text).font(PUI.Font.caption).foregroundStyle(ink.secondary)
                }
                CheckMark(selected)
                    .padding(.leading, PUI.Space.m)
            }
            .padding(.horizontal, PUI.Space.l)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(kind.displayName), \(status.text)")
    }
}

private extension ProviderKind {
    /// The tile color of the provider in the list.
    var tileColor: Color {
        switch self {
        case .whisperCpp: return .gray
        case .apple: return .blue
        case .elevenLabs: return .indigo
        case .openAI: return .teal
        case .groq: return .orange
        }
    }

    /// The provider's name on its test button.
    var testName: String {
        switch self {
        case .whisperCpp: return "whisper.cpp"
        case .apple: return "Apple"
        default: return displayName
        }
    }
}

// MARK: - whisper.cpp

private struct WhisperSettings: View {
    @AppStorage(Keys.whisperPath) private var whisperPath = ""
    @AppStorage(Keys.whisperModel) private var whisperModel = ""
    @ObservedObject private var models = WhisperModels.shared
    let onChange: () -> Void

    var body: some View {
        SettingsGroup("Model", footer: "Models are downloaded from Hugging Face into ~/Library/Application Support/Kaiku/models. Larger models are more accurate but slower.") {
            ForEach(WhisperModel.catalog) { model in
                ModelRow(model: model, active: whisperModel == model.localURL.path)
            }
            GroupRow {
                HStack(spacing: PUI.Space.s) {
                    if !WhisperModel.catalog.contains(where: { whisperModel == $0.localURL.path }) && !whisperModel.isEmpty {
                        Label((whisperModel as NSString).lastPathComponent, systemImage: "doc")
                            .font(PUI.Font.callout)
                            .foregroundStyle(FileManager.default.fileExists(atPath: whisperModel) ? Color.primary : Color.red)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: PUI.Space.m)
                    Button("Show Models Folder") {
                        try? FileManager.default.createDirectory(at: WhisperModels.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(WhisperModels.directory)
                    }
                    Button("Choose File…", action: chooseModel)
                }
                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            }
        }
        .onChange(of: models.version) { _, _ in onChange() }
        .onChange(of: whisperModel) { _, _ in onChange() }

        SettingsGroup("whisper.cpp", footer: "Leave empty to use the whisper-cli bundled with the app. Detect clears a custom path.") {
            PathField(label: "whisper-cli", path: $whisperPath, placeholder: "Automatic",
                      fallback: WhisperModels.detectWhisperCLI()) {
                whisperPath = ""
            }
            .onChange(of: whisperPath) { _, _ in onChange() }
        }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        panel.prompt = "Use Model"
        panel.directoryURL = WhisperModels.directory
        if panel.runModal() == .OK, let url = panel.url { whisperModel = url.path }
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    let active: Bool
    @ObservedObject private var models = WhisperModels.shared

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let progress = models.progress[model.file]
        let installed = model.isInstalled
        let ink = Ink(scheme)
        HStack(spacing: PUI.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: PUI.Space.s) {
                    Text(model.name).font(PUI.Font.body).foregroundStyle(ink.primary)
                    if model == WhisperModel.recommended {
                        Badge("Recommended")
                    }
                }
                Text("\(model.size) · \(model.note)").font(PUI.Font.caption).foregroundStyle(ink.secondary)
                if let err = models.errors[model.file] {
                    Text(err).font(PUI.Font.caption).foregroundStyle(ink.red)
                }
            }
            Spacer(minLength: PUI.Space.m)
            if let progress {
                ProgressView(value: progress).frame(width: 110)
                Text("\(Int(progress * 100))%").font(PUI.Font.caption).monospacedDigit().foregroundStyle(ink.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button { models.cancel(model) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(ink.secondary)
                    .help("Cancel download")
                    .accessibilityLabel("Cancel download")
            } else if active && installed {
                HStack(spacing: PUI.Space.xs) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text("In Use").font(PUI.Font.callout.weight(.medium))
                }
                .foregroundStyle(AppAccent.kaiku.legible(scheme))
            } else if installed {
                Button("Use") { models.use(model) }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            } else {
                Button { models.download(model) } label: {
                    Label("Download", systemImage: "arrow.down.circle").labelStyle(TightLabelStyle())
                }
                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            }
        }
        .padding(.horizontal, PUI.Space.l)
        .frame(minHeight: 42)
    }
}

// MARK: - Apple

private struct AppleSettings: View {
    @ObservedObject var speech: SpeechModelStatus
    let language: String
    let download: () -> Void

    var body: some View {
        SettingsGroup(Text(ProviderKind.apple.displayName), footer: Text("The speech recognizer built into macOS 26. Free and private: audio is transcribed on this Mac and never leaves it. There is no API key and no model to choose.")) {
            SettingsRow(Text("Language"), subtitle: Text("The default for new calls, set in General.")) {
                ValueText(LanguagePicker.recognizerName(language))
            }
            if AppSettings.normalizedLanguage(language) == "auto" {
                GroupRow {
                    Text("The recognizer can't detect the language, so Auto-detect transcribes in your Mac's language.")
                        .font(PUI.Font.callout).foregroundStyle(.secondary)
                }
            }
            SpeechModelStatusRow(readiness: speech.readiness, readyText: "Ready. The speech model is on this Mac.",
                                 downloadNote: "Calls are transcribed once it is downloaded.", download: download)
            if let error = speech.downloadError {
                GroupRow { StatusDot(kind: .error, text: error) }
            }
        }
    }
}

// MARK: - Cloud providers

private struct CloudProviderSettings: View {
    let kind: ProviderKind
    let onChange: () -> Void
    @State private var apiKey = ""
    @State private var reveal = false
    @State private var model = ""
    @State private var customModel = false

    var body: some View {
        SettingsGroup(Text(kind.displayName), footer: Text(modelHint)) {
            SettingsRow("API key") {
                HStack(spacing: PUI.Space.s) {
                    Group {
                        if reveal {
                            TextField("API key", text: $apiKey, prompt: Text("Paste your key"))
                        } else {
                            SecureField("API key", text: $apiKey, prompt: Text("Paste your key"))
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .font(.body.monospaced())
                    .frame(maxWidth: 280)
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(reveal ? "Hide key" : "Show key")
                    .accessibilityLabel(reveal ? "Hide key" : "Show key")
                }
            }
            GroupRow {
                HStack {
                    Label("Saved in your Keychain", systemImage: "lock.fill")
                        .font(PUI.Font.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let url = kind.keyURL {
                        Link("Get an API key", destination: url).font(PUI.Font.caption)
                    }
                }
            }

            SettingsRow("Model") {
                Picker("Model", selection: Binding(
                    get: { customModel ? "__custom" : model },
                    set: { v in
                        if v == "__custom" { customModel = true } else { customModel = false; model = v }
                    })) {
                    ForEach(kind.modelPresets, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Custom…").tag("__custom")
                }
                .labelsHidden()
                .fixedSize()
            }
            if customModel {
                SettingsRow("Model ID") {
                    TextField("Model ID", text: $model, prompt: Text(kind.defaultModel))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
        }
        .onAppear {
            apiKey = Keychain.get(kind.rawValue) ?? ""
            model = AppSettings.model(for: kind)
            customModel = !kind.modelPresets.contains(model)
        }
        .onChange(of: apiKey) { _, v in
            Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: kind.rawValue)
            onChange()
        }
        .onChange(of: model) { _, v in AppSettings.defaults.set(v, forKey: Keys.model(kind)) }
    }

    private var modelHint: String {
        switch kind {
        case .elevenLabs: return "Scribe tells voices apart on the call audio, so other people show up as Speaker 1, Speaker 2…"
        case .openAI:
            switch model {
            case "whisper-1": return "whisper-1 returns timestamps for every sentence."
            case "gpt-4o-transcribe-diarize": return "Tells voices apart on the call audio. Audio is sent in 10-minute parts."
            default: return "gpt-4o models return text without timestamps, so audio is sent in 1-minute parts to keep the timeline."
            }
        case .groq: return "Groq runs Whisper with timestamps, very fast and cheap."
        case .whisperCpp, .apple: return ""
        }
    }
}

// MARK: - Test

private struct ProviderTestSection: View {
    let kind: ProviderKind
    @State private var running = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        SettingsGroup(footer: !kind.isCloud ? "Runs locally, nothing leaves your Mac." : "Sends one second of audio. Costs a fraction of a cent.") {
            GroupRow {
                HStack(spacing: PUI.Space.m) {
                    Button {
                        running = true
                        result = nil
                        Task {
                            let r = await ProviderTester.test(kind)
                            withAnimation { result = r; running = false }
                        }
                    } label: {
                        Label("Test \(kind.testName)", systemImage: "checkmark.seal")
                            .labelStyle(TightLabelStyle())
                    }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    .disabled(running)
                    if running {
                        ProgressView().controlSize(.small)
                        Text("Transcribing a 1-second test sound…").font(PUI.Font.callout).foregroundStyle(.secondary)
                    } else if let result {
                        StatusDot(kind: result.ok ? .ok : .error, text: result.message)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Silence trimming

private struct SilenceTrimSection: View {
    @AppStorage(Keys.trimSilence) private var mode = TrimSilenceMode.cloud.rawValue
    @AppStorage(Keys.trimThresholdDB) private var threshold = -45.0
    @AppStorage(Keys.trimMinSilence) private var minSilence = 2.0

    var body: some View {
        SettingsGroup("Silence", footer: "Long pauses are cut from a temporary copy sent for transcription, so cloud providers bill fewer minutes. Your audio files are never changed and timestamps still match the recording.") {
            SettingsRow("Skip long silences") {
                Picker("Skip long silences", selection: $mode) {
                    ForEach(TrimSilenceMode.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if mode != TrimSilenceMode.off.rawValue {
                SettingsRow("Silence below") {
                    HStack(spacing: PUI.Space.s) {
                        ValueText("\(Int(threshold)) dB")
                        Stepper("Silence below", value: $threshold, in: -70 ... -25, step: 5).labelsHidden()
                    }
                }
                SettingsRow("Lasting at least") {
                    HStack(spacing: PUI.Space.s) {
                        ValueText(String(format: "%.1f s", minSilence))
                        Stepper("Lasting at least", value: $minSilence, in: 1...10, step: 0.5).labelsHidden()
                    }
                }
            }
        }
    }
}

// MARK: - Prices

private struct PriceSection: View {
    let kind: ProviderKind
    @State private var prices: [String: Double] = [:]

    private var models: [String] {
        var list = kind.modelPresets
        let current = AppSettings.model(for: kind)
        if !list.contains(current) { list.append(current) }
        return list
    }

    var body: some View {
        if kind.isCloud {
            SettingsGroup("Cost Estimate", footer: "Used for the estimated cost shown in the library and sent with the webhook. Defaults are the providers' list prices from September 2026; check your plan, prices change. Transcribing on this Mac is free.") {
                ForEach(models, id: \.self) { model in
                    SettingsRow(model) {
                        HStack(spacing: 4) {
                            Text("$").foregroundStyle(.secondary)
                            TextField(model, value: Binding(
                                get: { prices[model] ?? CostEstimator.pricePerHour(model: model, overrides: [:]) ?? 0 },
                                set: { v in
                                    prices[model] = v
                                    var o = AppSettings.priceOverrides
                                    if v == CostEstimator.defaultPricesPerHour[model] { o[model] = nil } else { o[model] = v }
                                    AppSettings.priceOverrides = o
                                }), format: .number.precision(.fractionLength(0...4)))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("per hour").foregroundStyle(.secondary)
                        }
                    }
                }
                GroupRow {
                    HStack {
                        Spacer()
                        Button("Reset to List Prices") {
                            var o = AppSettings.priceOverrides
                            models.forEach { o[$0] = nil }
                            AppSettings.priceOverrides = o
                            prices = [:]
                        }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
            .onAppear { prices = AppSettings.priceOverrides }
        }
    }
}

// MARK: - Summary

private struct SummarySettings: View {
    @AppStorage(Keys.summaryEnabled) private var enabled = false
    @AppStorage(Keys.summaryProvider) private var provider = SummaryProviderKind.openAI.rawValue
    @AppStorage(Keys.summaryPrompt) private var prompt = SummaryAPI.defaultPrompt
    @State private var model = ""
    @State private var anthropicKey = ""

    private var kind: SummaryProviderKind { SummaryProviderKind(rawValue: provider) ?? .openAI }

    var body: some View {
        SettingsGroup("Summary", footer: "Off by default. Sends the transcript to the provider you pick, with your own key, and saves summary.md in the call folder. You can also summarize any past call from the library.") {
            SwitchRow("Summarize every call after transcription", isOn: $enabled)
            SettingsRow("Provider") {
                Picker("Provider", selection: $provider) {
                    ForEach(SummaryProviderKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Model") {
                TextField("Model", text: $model, prompt: Text(kind.defaultModel))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
            }
            if kind == .anthropic {
                SettingsRow("API key") {
                    SecureField("API key", text: $anthropicKey, prompt: Text("Paste your key"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(maxWidth: 280)
                }
            }
            GroupRow {
                HStack {
                    if kind.apiKey != nil || !anthropicKey.isEmpty {
                        StatusDot(kind: .ok, text: kind == .anthropic ? "Key saved in your Keychain" : "Uses the \(kind.displayName) key saved for transcription")
                    } else {
                        StatusDot(kind: .warning, text: kind == .anthropic ? "API key missing" : "No \(kind.displayName) key yet. Select \(kind.displayName) under Provider to add one.")
                    }
                    Spacer()
                    if let url = kind.keyURL { Link("Get an API key", destination: url).font(PUI.Font.caption) }
                }
            }
            GroupRow {
                VStack(alignment: .leading, spacing: PUI.Space.s) {
                    HStack {
                        Text("Prompt").font(PUI.Font.body)
                        Spacer()
                        Button("Reset") { prompt = SummaryAPI.defaultPrompt }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                            .disabled(prompt == SummaryAPI.defaultPrompt)
                    }
                    EditorField(text: $prompt, minHeight: 140)
                    Text("{{title}} and {{transcript}} are filled in for you.").font(PUI.Font.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            model = AppSettings.summaryModel(for: kind)
            anthropicKey = Keychain.get(SummaryProviderKind.anthropic.keyAccount) ?? ""
        }
        .onChange(of: provider) { _, _ in model = AppSettings.summaryModel(for: kind) }
        .onChange(of: model) { _, v in AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.summaryModel(kind)) }
        .onChange(of: anthropicKey) { _, v in
            Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: SummaryProviderKind.anthropic.keyAccount)
        }
    }
}

/// Text field for an executable path with a validity indicator and an optional Detect button.
struct PathField: View {
    let label: String
    @Binding var path: String
    let placeholder: String
    /// Executable used when the field is empty.
    var fallback: String?
    var detect: (() -> Void)?

    var body: some View {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let effective = trimmed.isEmpty ? (fallback ?? "") : (trimmed as NSString).expandingTildeInPath
        let ok = FileManager.default.isExecutableFile(atPath: effective)
        SettingsRow(label) {
            HStack(spacing: PUI.Space.s) {
                TextField(label, text: $path, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .font(.body.monospaced())
                    .frame(maxWidth: 300)
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red)
                    .help(ok ? "Found" : "Not found or not executable")
                    .accessibilityLabel(ok ? "Found" : "Not found")
                if let detect {
                    Button("Detect", action: detect)
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
            }
        }
    }
}
