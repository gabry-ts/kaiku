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

    /// The system recognizer transcribes after the call or live, where it can't detect the language.
    private var usesAppleRecognizer: Bool {
        kind == .apple || (AppSettings.liveEnabled && AppSettings.liveEngine == .apple)
    }

    var body: some View {
        KaikuPane(pane: .transcription, subtitle: "How your calls become text, during and after the call.") {
            SettingsGroup("Language", footer: "Auto-detect handles most calls, even mixed languages. You can change it per call.") {
                LanguagePicker(language: $language, label: "Default language")
                if AppSettings.normalizedLanguage(language) == "auto" && usesAppleRecognizer {
                    GroupRow {
                        Text("Apple's recognizer can't detect the language, so Auto-detect transcribes in your Mac's language.")
                            .font(PUI.Font.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .settingsAnchor("language")

            SettingsGroup("Provider", footer: "Your microphone and the call audio are transcribed separately, so Kaiku knows who said what.") {
                ForEach(ProviderKind.allCases) { p in
                    ProviderRow(kind: p, selected: p == kind, status: status(of: p), refresh: refresh) {
                        provider = p.rawValue
                    }
                }
            }
            .settingsAnchor("provider")

            Group {
                if kind == .whisperCpp {
                    WhisperSettings(onChange: { refresh += 1 })
                } else if kind == .apple {
                    AppleSettings(speech: speech) { Task { await downloadSpeechModel() } }
                } else {
                    CloudProviderSettings(kind: kind, onChange: { refresh += 1 }).id(kind)
                }
            }
            .settingsAnchor("model")

            SpeakerNamesSection()
            LiveSettings()
            AdvancedTranscriptionSettings(kind: kind, onChange: { refresh += 1 })
        }
        .task(id: language) { await refreshSpeechModel() }
    }

    /// A provider's state in the list. Apple's is the state of its speech model.
    private func status(of provider: ProviderKind) -> (ready: Bool, text: String) {
        guard provider.isAvailable else { return (false, "Needs macOS 26") }
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
        HStack(spacing: PUI.Space.m) {
            Button(action: select) {
                HStack(spacing: PUI.Space.m + 2) {
                    IconTile(kind.symbol, color: kind.tileColor, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.displayName).font(PUI.Font.body).foregroundStyle(ink.primary)
                        Text(kind.tagline).font(PUI.Font.caption).foregroundStyle(ink.secondary)
                    }
                    Spacer(minLength: PUI.Space.l)
                    HStack(spacing: PUI.Space.xs) {
                        Circle().fill(status.ready ? ink.green : (selected ? ink.orange : ink.tertiary)).frame(width: 6, height: 6)
                        Text(status.text).font(PUI.Font.caption).foregroundStyle(ink.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!kind.isAvailable)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel("\(kind.displayName), \(status.text)")
            if kind.readiness == .needsKey, let service = AccountService.of(kind) {
                Button("Set Up…") { WindowManager.shared.showSettings(.accounts, anchor: service.anchor) }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    .controlSize(.mini)
            }
            CheckMark(selected)
                .padding(.leading, PUI.Space.xs)
        }
        .padding(.horizontal, PUI.Space.l)
        .frame(minHeight: 44)
        .opacity(kind.isAvailable ? 1 : 0.5)
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
        case .alibaba: return .red
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
    @AppStorage(Keys.whisperModel) private var whisperModel = ""
    @ObservedObject private var models = WhisperModels.shared
    let onChange: () -> Void

    var body: some View {
        SettingsGroup("Model", footer: "Larger models are more accurate but slower. Downloaded from Hugging Face into ~/Library/Application Support/Kaiku/models.") {
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
            ProviderTestRow(kind: .whisperCpp)
        }
        .onChange(of: models.version) { _, _ in onChange() }
        .onChange(of: whisperModel) { _, _ in onChange() }
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
    let download: () -> Void

    var body: some View {
        SettingsGroup(Text("Model"), footer: Text("Built into macOS. Nothing leaves your Mac.")) {
            SpeechModelStatusRow(readiness: speech.readiness, readyText: "Ready. The speech model is on this Mac.",
                                 downloadNote: "Calls are transcribed once it is downloaded.", download: download)
            if let error = speech.downloadError {
                GroupRow { StatusDot(kind: .error, text: error) }
            }
            ProviderTestRow(kind: .apple)
        }
    }
}

// MARK: - Cloud providers

private struct CloudProviderSettings: View {
    let kind: ProviderKind
    let onChange: () -> Void
    @State private var model = ""
    @State private var customModel = false

    var body: some View {
        SettingsGroup(Text("Model"), footer: Text(modelHint)) {
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
            CloudKeyStatusRow(kind: kind)
            ProviderTestRow(kind: kind)
        }
        .onAppear {
            model = AppSettings.model(for: kind)
            customModel = !kind.modelPresets.contains(model)
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
        case .alibaba:
            if AlibabaProvider.isChunked(model) {
                return "qwen3-asr-flash returns text without timestamps, so audio is sent in parts of under 5 minutes. The key must belong to the chosen region."
            }
            return "The recording is uploaded to Alibaba's temporary storage (deleted after 48 hours) and transcribed with sentence timestamps. Fun-ASR, Paraformer and Qwen-Audio tell voices apart on the call audio. The key must belong to the chosen region."
        case .whisperCpp, .apple: return ""
        }
    }
}

/// Whether the cloud provider's key is saved, with Set Up… when it isn't.
struct CloudKeyStatusRow: View {
    let kind: ProviderKind

    var body: some View {
        GroupRow {
            HStack(spacing: PUI.Space.m) {
                if let error = Keychain.errors[kind.rawValue] {
                    StatusDot(kind: .error, text: error)
                } else if Keychain.apiKey(for: kind) == nil {
                    StatusDot(kind: .warning, text: "No \(kind.displayName) key yet")
                } else {
                    StatusDot(kind: .ok, text: "Uses your \(kind.displayName) key")
                }
                Spacer(minLength: PUI.Space.m)
                if Keychain.apiKey(for: kind) == nil, let service = AccountService.of(kind) { SetUpButton(service: service) }
            }
        }
    }
}

// MARK: - Test

/// Transcribes a second of sound with the provider, at the bottom of its Model group.
private struct ProviderTestRow: View {
    let kind: ProviderKind
    @State private var running = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        GroupRow {
            VStack(alignment: .leading, spacing: PUI.Space.xs) {
                HStack(spacing: PUI.Space.m) {
                    Button {
                        running = true
                        result = nil
                        Task {
                            let r = await ProviderTester.test(kind)
                            result = r
                            running = false
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
                Text(kind.isCloud ? "Sends one second of audio." : "Runs on this Mac.")
                    .font(PUI.Font.caption).foregroundStyle(.secondary)
            }
        }
        .id("test-\(kind.rawValue)")
    }
}

// MARK: - Speaker names

private struct SpeakerNamesSection: View {
    @AppStorage(Keys.meLabel) private var meLabel = "Me"
    @AppStorage(Keys.othersLabel) private var othersLabel = "Others"

    var body: some View {
        SettingsGroup("Speaker Names", footer: "Providers that tell voices apart add Speaker 1, Speaker 2… Rename them per call.") {
            SettingsRow("Your microphone") {
                TextField("Your microphone", text: $meLabel, prompt: Text("Me"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
            }
            SettingsRow("Call audio") {
                TextField("Call audio", text: $othersLabel, prompt: Text("Others"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
            }
        }
        .settingsAnchor("speakers")
    }
}

// MARK: - Advanced

/// whisper-cli, silence trimming and prices, folded away. Opens by itself when whisper-cli
/// can't be found, or when a link points inside it.
private struct AdvancedTranscriptionSettings: View {
    let kind: ProviderKind
    let onChange: () -> Void
    @AppStorage(Keys.whisperPath) private var whisperPath = ""
    @AppStorage(Keys.liveEnabled) private var liveEnabled = false
    @AppStorage(Keys.liveEngine) private var liveEngine = LiveEngineKind.apple.rawValue
    @ObservedObject private var nav = AppNavigation.shared
    @State private var open = false
    @Environment(\.colorScheme) private var scheme

    private static let anchors: Set<String> = ["advanced", "whisperCli", "silence", "prices"]

    /// whisper.cpp transcribes after the call or live.
    private var usesWhisper: Bool {
        kind == .whisperCpp || (liveEnabled && LiveTranscription.isSupported && liveEngine == LiveEngineKind.whisper.rawValue)
    }

    private var whisperMissing: Bool { usesWhisper && !FileManager.default.isExecutableFile(atPath: AppSettings.whisperPath) }

    var body: some View {
        let ink = Ink(scheme)
        SettingsGroup {
            Button { open.toggle() } label: {
                HStack(spacing: PUI.Space.s) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ink.tertiary)
                        .frame(width: 12)
                    Text("Advanced").font(PUI.Font.body).foregroundStyle(ink.primary)
                    Spacer()
                    Text(summary).font(PUI.Font.callout).foregroundStyle(ink.secondary)
                }
                .padding(.horizontal, PUI.Space.l)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced")
            .accessibilityValue(open ? "Shown" : "Hidden")
        }
        .settingsAnchor("advanced")
        .onAppear {
            if whisperMissing || nav.wants(Self.anchors, in: .transcription) { open = true }
        }
        .onChange(of: nav.request) { _, _ in if nav.wants(Self.anchors, in: .transcription) { open = true } }

        if open {
            if usesWhisper {
                SettingsGroup("whisper-cli", footer: "Leave empty to use the one bundled with Kaiku.") {
                    PathField(label: "whisper-cli", path: $whisperPath, placeholder: "Automatic",
                              fallback: WhisperModels.detectWhisperCLI()) {
                        whisperPath = ""
                    }
                    .onChange(of: whisperPath) { _, _ in onChange() }
                }
                .settingsAnchor("whisperCli")
            }
            SilenceTrimSection()
                .settingsAnchor("silence")
            PriceSection(kind: kind).id("price-\(kind.rawValue)")
                .settingsAnchor("prices")
        }
    }

    private var summary: String {
        var parts = ["Silence"]
        if usesWhisper { parts.insert("whisper-cli", at: 0) }
        if kind.isCloud { parts.append("Cost estimate") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Silence trimming

private struct SilenceTrimSection: View {
    @AppStorage(Keys.trimSilence) private var mode = TrimSilenceMode.cloud.rawValue
    @AppStorage(Keys.trimThresholdDB) private var threshold = -45.0
    @AppStorage(Keys.trimMinSilence) private var minSilence = 2.0

    var body: some View {
        SettingsGroup("Silence", footer: "Pauses are cut from a temporary copy, so cloud providers bill fewer minutes.") {
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
            SettingsGroup("Cost Estimate", footer: "Used for the estimates in the library and the webhook. List prices from September 2026.") {
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

/// Whether a summary provider can be used: its command-line tool found, its server running.
/// Keys, addresses and paths are edited in Settings > Accounts.
@MainActor
final class ProviderAccess: ObservableObject {
    @Published private(set) var kind: SummaryProviderKind = .openAI
    /// Where the CLI was found, nil when it wasn't.
    @Published private(set) var found: String?
    /// Whether the local server answers, nil while checking.
    @Published private(set) var serverRunning: Bool?
    private var probe: Task<Void, Never>?

    func load(_ kind: SummaryProviderKind) {
        self.kind = kind
        refresh()
        checkServer()
    }

    /// Asks the local server for something small, giving up after a few seconds.
    private func checkServer() {
        probe?.cancel()
        guard kind.isLocal else { serverRunning = nil; return }
        serverRunning = nil
        let kind = kind
        probe = Task {
            guard let url = kind.probeURL else { return }
            var req = URLRequest(url: url, timeoutInterval: 3)
            if let key = kind.apiKey { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            // Any HTTP answer, even a refusal, means something is listening.
            let up = (try? await URLSession.shared.data(for: req))?.1 is HTTPURLResponse
            guard !Task.isCancelled, self.kind == kind else { return }
            self.serverRunning = up
        }
    }

    private func refresh() {
        guard let cli = kind.cli else { found = nil; return }
        found = CLIProviders.locate(cli)
        guard found == nil else { return }
        Task {
            let path = await CLIProviders.detect(cli)
            if self.kind.cli == cli { self.found = path }
        }
    }

    /// Whether it can be used, and what to show: "Ready · …", or what is missing.
    func status(modelMissing: Bool) -> (ready: Bool, text: String, setUp: Bool) {
        if kind.cli != nil {
            guard let found else { return (false, "\(kind.displayName) not found", true) }
            return modelMissing ? (false, "Model required", false) : (true, "Ready · \(kind.displayName) at \(found)", false)
        }
        if kind.isLocal {
            if kind.problem != nil { return (false, "No \(kind.displayName) server address yet", true) }
            if serverRunning == false { return (false, "\(kind == .ollama ? "Ollama" : "The server") isn't running", true) }
            if modelMissing { return (false, "Model required", false) }
            let base = kind == .ollama ? LocalLLM.ollamaChatBase(kind.baseURL) : kind.baseURL
            let host = URL(string: base).flatMap { u in u.host.map { h in u.port.map { "\(h):\($0)" } ?? h } } ?? base
            return (true, "Ready · \(kind.displayName) on \(host), nothing leaves this Mac", false)
        }
        if let error = Keychain.errors[kind.keyAccount] { return (false, error, true) }
        if kind.apiKey == nil { return (false, "No \(kind.displayName) key yet", true) }
        if modelMissing { return (false, "Model required", false) }
        return (true, "Ready · uses your \(kind.displayName) key", false)
    }
}

/// Models the providers list, fetched when a model menu is first shown and kept in memory.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()
    @Published private(set) var models: [SummaryProviderKind: [String]] = [:]
    @Published private(set) var loading: Set<SummaryProviderKind> = []
    @Published private(set) var errors: [SummaryProviderKind: String] = [:]

    func load(_ kind: SummaryProviderKind, force: Bool = false) async {
        guard kind.listsModels, force || models[kind] == nil, !loading.contains(kind) else { return }
        loading.insert(kind)
        defer { loading.remove(kind) }
        do {
            models[kind] = try await fetch(kind)
            errors[kind] = nil
        } catch {
            errors[kind] = error.localizedDescription
        }
    }

    private func fetch(_ kind: SummaryProviderKind) async throws -> [String] {
        switch kind {
        case .openRouter:
            var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!, timeoutInterval: 30)
            if let key = kind.apiKey { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ProviderError(message: "Couldn't load the OpenRouter models.")
            }
            return try SummaryAPI.parseModelIDs(data)
        case .ollama:
            guard let url = LocalLLM.ollamaTagsURL(kind.baseURL) else { throw ProviderError(message: "Check the Ollama address.") }
            let data: Data
            let response: URLResponse
            do { (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)) }
            catch { throw ProviderError(message: "Ollama is not running.") }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ProviderError(message: "Couldn't load the Ollama models.")
            }
            return try LocalLLM.parseOllamaTags(data)
        case .opencode:
            guard let binary = await CLIProviders.detect(.opencode) else { throw ProviderError(message: "OpenCode CLI not found.") }
            return CLITool.parseOpenCodeModels(try await Shell.run(binary, ["models"], timeout: 30))
        default:
            return kind.cli?.modelSuggestions ?? []
        }
    }
}

/// Model name field with a menu of the models the provider lists or documents.
/// Typing filters the menu; any name can still be typed.
struct ModelField: View {
    let kind: SummaryProviderKind
    @Binding var text: String
    var title = "Model"
    var subtitle: String?
    @ObservedObject private var catalog = ModelCatalog.shared

    private var subtitleText: Text? {
        let parts = [subtitle, kind.modelHint].compactMap { $0 }
        return parts.isEmpty ? nil : Text(parts.joined(separator: " "))
    }

    private var choices: [String] {
        let all = catalog.models[kind] ?? []
        let query = text.trimmingCharacters(in: .whitespaces)
        let matches = all.filter { $0.localizedCaseInsensitiveContains(query) }
        return query.isEmpty || matches.isEmpty || matches == [query] ? all : matches
    }

    var body: some View {
        SettingsRow(Text(title), subtitle: subtitleText) {
            HStack(spacing: PUI.Space.s) {
                TextField(title, text: $text, prompt: Text(kind.modelPlaceholder))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
                if kind.listsModels {
                    Menu {
                        if kind.cli != nil { Button("CLI default") { text = "" } }
                        if catalog.loading.contains(kind) {
                            Text("Loading…")
                        } else if let error = catalog.errors[kind] {
                            Text(error)
                        }
                        ForEach(choices, id: \.self) { name in Button(name) { text = name } }
                        if kind != .claudeCode {
                            Divider()
                            Button("Refresh List") { Task { await catalog.load(kind, force: true) } }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .help("Choose a model")
                }
            }
        }
        .task(id: kind) { await catalog.load(kind) }
    }
}

/// Whether the provider is ready, with Set Up… leading to its row in Accounts when it isn't.
struct ProviderStatusRow: View {
    @ObservedObject var access: ProviderAccess
    /// True when the provider needs a model and none is set.
    var modelMissing = false

    var body: some View {
        let status = access.status(modelMissing: modelMissing)
        GroupRow {
            HStack(spacing: PUI.Space.m) {
                StatusDot(kind: status.ready ? .ok : .warning, text: status.text)
                Spacer(minLength: PUI.Space.m)
                if status.setUp { SetUpButton(service: AccountService.of(access.kind)) }
            }
        }
    }
}

/// Opens the service's row in Settings > Accounts.
struct SetUpButton: View {
    let service: AccountService

    var body: some View {
        Button("Set Up…") { WindowManager.shared.showSettings(.accounts, anchor: service.anchor) }
            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            .help("Add it in Accounts")
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
