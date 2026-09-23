import SwiftUI
import McRofoneCore

struct TranscriptionSettings: View {
    @AppStorage(Keys.provider) private var provider = ProviderKind.whisperCpp.rawValue
    @AppStorage(Keys.ffmpegPath) private var ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    /// Bumped to re-evaluate readiness after keys or models change.
    @State private var refresh = 0

    private var kind: ProviderKind { ProviderKind(rawValue: provider) ?? .whisperCpp }

    var body: some View {
        Form {
            Section {
                ForEach(ProviderKind.allCases) { p in
                    ProviderRow(kind: p, selected: p == kind, refresh: refresh) {
                        withAnimation(.snappy) { provider = p.rawValue }
                    }
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("Your microphone and the call audio are transcribed separately, so the transcript knows who said what.")
            }

            if kind == .whisperCpp {
                WhisperSettings(onChange: { refresh += 1 })
            } else {
                CloudProviderSettings(kind: kind, onChange: { refresh += 1 }).id(kind)
            }

            ProviderTestSection(kind: kind).id("test-\(kind.rawValue)")

            SilenceTrimSection()
            PriceSection(kind: kind).id("price-\(kind.rawValue)")
            SummarySettings()

            Section {
                PathField(label: "ffmpeg", path: $ffmpegPath, placeholder: "/opt/homebrew/bin/ffmpeg")
            } header: {
                Text("Tools")
            } footer: {
                Text("ffmpeg converts and compresses audio for every provider. Install it with `brew install ffmpeg`.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderRow: View {
    let kind: ProviderKind
    let selected: Bool
    let refresh: Int
    let select: () -> Void

    var body: some View {
        let readiness = kind.readiness
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? .white : .primary)
                    .frame(width: 30, height: 30)
                    .background(selected ? AnyShapeStyle(Brand.accent.gradient) : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName).font(.body.weight(.medium))
                    Text(kind.tagline).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(readiness == .ready ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(readiness.text).font(.callout).foregroundStyle(.secondary)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Brand.accent : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(kind.displayName), \(readiness.text)")
    }
}

// MARK: - whisper.cpp

private struct WhisperSettings: View {
    @AppStorage(Keys.whisperPath) private var whisperPath = "/opt/homebrew/bin/whisper-cli"
    @AppStorage(Keys.whisperModel) private var whisperModel = ""
    @ObservedObject private var models = WhisperModels.shared
    let onChange: () -> Void

    var body: some View {
        Section {
            ForEach(WhisperModel.catalog) { model in
                ModelRow(model: model, active: whisperModel == model.localURL.path)
            }
            HStack {
                if !WhisperModel.catalog.contains(where: { whisperModel == $0.localURL.path }) && !whisperModel.isEmpty {
                    Label((whisperModel as NSString).lastPathComponent, systemImage: "doc")
                        .foregroundStyle(FileManager.default.fileExists(atPath: whisperModel) ? Color.primary : Color.red)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Show Models Folder") {
                    try? FileManager.default.createDirectory(at: WhisperModels.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(WhisperModels.directory)
                }
                Button("Choose File…", action: chooseModel)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Models are downloaded from Hugging Face into ~/Library/Application Support/mc.Rofone/models. Larger models are more accurate but slower.")
        }
        .onChange(of: models.version) { _, _ in onChange() }
        .onChange(of: whisperModel) { _, _ in onChange() }

        Section("whisper.cpp") {
            PathField(label: "whisper-cli", path: $whisperPath, placeholder: "/opt/homebrew/bin/whisper-cli") {
                if let found = WhisperModels.detectWhisperCLI() { whisperPath = found }
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

    var body: some View {
        let progress = models.progress[model.file]
        let installed = model.isInstalled
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.name).font(.body.weight(active ? .semibold : .regular))
                    if model == WhisperModel.recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Brand.accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(Brand.accent)
                    }
                }
                Text("\(model.size) · \(model.note)").font(.callout).foregroundStyle(.secondary)
                if let err = models.errors[model.file] {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 110)
                Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                Button { models.cancel(model) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Cancel download")
            } else if active && installed {
                Label("In Use", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.weight(.medium))
            } else if installed {
                Button("Use") { models.use(model) }
            } else {
                Button { models.download(model) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
        .padding(.vertical, 1)
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
        Section {
            LabeledContent("API key") {
                HStack(spacing: 6) {
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
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(reveal ? "Hide key" : "Show key")
                    .accessibilityLabel(reveal ? "Hide key" : "Show key")
                }
            }
            HStack {
                Label("Saved in your Keychain", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = kind.keyURL {
                    Link("Get an API key", destination: url).font(.caption)
                }
            }

            Picker("Model", selection: Binding(
                get: { customModel ? "__custom" : model },
                set: { v in
                    if v == "__custom" { customModel = true } else { customModel = false; model = v }
                })) {
                ForEach(kind.modelPresets, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("Custom…").tag("__custom")
            }
            if customModel {
                TextField("Model ID", text: $model, prompt: Text(kind.defaultModel))
            }
        } header: {
            Text(kind.displayName)
        } footer: {
            Text(modelHint)
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
        case .whisperCpp: return ""
        }
    }
}

// MARK: - Test

private struct ProviderTestSection: View {
    let kind: ProviderKind
    @State private var running = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    running = true
                    result = nil
                    Task {
                        let r = await ProviderTester.test(kind)
                        withAnimation { result = r; running = false }
                    }
                } label: {
                    Label("Test \(kind == .whisperCpp ? "whisper.cpp" : kind.displayName)", systemImage: "checkmark.seal")
                }
                .disabled(running)
                if running {
                    ProgressView().controlSize(.small)
                    Text("Transcribing a 1-second test sound…").font(.callout).foregroundStyle(.secondary)
                } else if let result {
                    StatusDot(kind: result.ok ? .ok : .error, text: result.message)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
            }
        } footer: {
            Text(kind == .whisperCpp ? "Runs locally, nothing leaves your Mac." : "Sends one second of audio. Costs a fraction of a cent.")
        }
    }
}

// MARK: - Silence trimming

private struct SilenceTrimSection: View {
    @AppStorage(Keys.trimSilence) private var mode = TrimSilenceMode.cloud.rawValue
    @AppStorage(Keys.trimThresholdDB) private var threshold = -45.0
    @AppStorage(Keys.trimMinSilence) private var minSilence = 2.0

    var body: some View {
        Section {
            Picker("Skip long silences", selection: $mode) {
                ForEach(TrimSilenceMode.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            if mode != TrimSilenceMode.off.rawValue {
                Stepper(value: $threshold, in: -70 ... -25, step: 5) {
                    LabeledContent("Silence below", value: "\(Int(threshold)) dB")
                }
                Stepper(value: $minSilence, in: 1...10, step: 0.5) {
                    LabeledContent("Lasting at least", value: String(format: "%.1f s", minSilence))
                }
            }
        } header: {
            Text("Silence")
        } footer: {
            Text("Long pauses are cut from a temporary copy sent for transcription, so cloud providers bill fewer minutes. Your audio files are never changed and timestamps still match the recording.")
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
        if kind != .whisperCpp {
            Section {
                ForEach(models, id: \.self) { model in
                    LabeledContent(model) {
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
                HStack {
                    Spacer()
                    Button("Reset to List Prices") {
                        var o = AppSettings.priceOverrides
                        models.forEach { o[$0] = nil }
                        AppSettings.priceOverrides = o
                        prices = [:]
                    }
                }
            } header: {
                Text("Cost Estimate")
            } footer: {
                Text("Used for the estimated cost shown in the library and sent with the webhook. Defaults are the providers' list prices from September 2026; check your plan, prices change. whisper.cpp is free.")
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
        Section {
            Toggle("Summarize every call after transcription", isOn: $enabled)
            Picker("Provider", selection: $provider) {
                ForEach(SummaryProviderKind.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            TextField("Model", text: $model, prompt: Text(kind.defaultModel))
            if kind == .anthropic {
                LabeledContent("API key") {
                    SecureField("API key", text: $anthropicKey, prompt: Text("Paste your key"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
            }
            HStack {
                if kind.apiKey != nil || !anthropicKey.isEmpty {
                    StatusDot(kind: .ok, text: kind == .anthropic ? "Key saved in your Keychain" : "Uses the \(kind.displayName) key saved for transcription")
                } else {
                    StatusDot(kind: .warning, text: kind == .anthropic ? "API key missing" : "No \(kind.displayName) key yet. Select \(kind.displayName) under Provider to add one.")
                }
                Spacer()
                if let url = kind.keyURL { Link("Get an API key", destination: url).font(.caption) }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Prompt")
                    Spacer()
                    Button("Reset") { prompt = SummaryAPI.defaultPrompt }
                        .disabled(prompt == SummaryAPI.defaultPrompt)
                }
                TextEditor(text: $prompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Text("{{title}} and {{transcript}} are filled in for you.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Summary")
        } footer: {
            Text("Off by default. Sends the transcript to the provider you pick, with your own key, and saves summary.md in the call folder. You can also summarize any past call from the library.")
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
    var detect: (() -> Void)?

    var body: some View {
        let ok = FileManager.default.isExecutableFile(atPath: (path as NSString).expandingTildeInPath)
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, text: $path, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .font(.body.monospaced())
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red)
                    .help(ok ? "Found" : "Not found or not executable")
                    .accessibilityLabel(ok ? "Found" : "Not found")
                if let detect {
                    Button("Detect", action: detect)
                }
            }
        }
    }
}
