import AppKit
import KaikuCore
import PartitiUI
import SwiftUI

/// Settings > Dictation: speak in any app and the text is typed where the cursor is.
struct DictationSettings: View {
    @AppStorage(Keys.dictationEnabled) private var enabled = false

    var body: some View {
        KaikuPane(pane: .dictation, subtitle: "Speak in any app and the text appears where the cursor is.") {
            SettingsGroup("Dictation", footer: "Off until you turn it on: no shortcut is registered and nothing listens before that.") {
                SwitchRow("Dictate with a shortcut in any app", isOn: $enabled)
            }
            .settingsAnchor("dictation")
            if enabled {
                DictationActivationSection()
                DictationSpeechSection()
                DictationPolishSection()
                DictationModesSection()
                DictationInsertionSection()
                DictationHistorySection()
            }
        }
        .onChange(of: enabled) { _, _ in DictationController.shared.apply() }
    }
}

// MARK: - Activation

private struct DictationActivationSection: View {
    @AppStorage(Keys.dictationActivation) private var activation = DictationActivation.hold.rawValue

    var body: some View {
        SettingsGroup("Shortcut", footer: "Hold to talk records while the keys are down. Press to start and stop records until you press again. Esc cancels a dictation.") {
            SettingsRow("Activation") {
                Picker("Activation", selection: $activation) {
                    ForEach(DictationActivation.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            DictationShortcutRows()
        }
        .settingsAnchor("activation")
    }
}

/// The two dictation shortcuts, recorded the way Settings > Menu Bar & Shortcuts records the others.
private struct DictationShortcutRows: View {
    private static let actions: [ShortcutAction] = [.dictate, .dictationMode]
    @State private var combos = Shortcuts.assignments
    @State private var recording: ShortcutAction?
    @State private var warnings: [ShortcutAction: String] = [:]
    @State private var monitor: Any?

    var body: some View {
        ForEach(Self.actions) { action in
            GroupRow {
                VStack(alignment: .leading, spacing: PUI.Space.s) {
                    HStack(spacing: PUI.Space.s) {
                        Text(action.title).font(PUI.Font.body)
                        Spacer(minLength: PUI.Space.l)
                        Button {
                            recording == action ? stopRecording() : startRecording(action)
                        } label: {
                            Text(recording == action ? "Type shortcut…" : combos[action]?.display ?? "None")
                                .monospacedDigit()
                                .foregroundStyle(combos[action] == nil && recording != action ? .secondary : .primary)
                                .frame(minWidth: 120)
                        }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        .accessibilityLabel("\(action.title) shortcut")
                        .accessibilityValue(combos[action]?.display ?? "None")
                        Button {
                            commit(action) { Shortcuts.reset(action) }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(combos[action] == action.defaultCombo)
                        .help("Reset to \(action.defaultCombo?.display ?? "None")")
                        .accessibilityLabel("Reset \(action.title) shortcut")
                    }
                    if let warning = warnings[action] { StatusDot(kind: .warning, text: warning) }
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        warnings[action] = nil
        recording = action
        HotKeyManager.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        HotKeyManager.resume()
    }

    private func handle(_ event: NSEvent) {
        guard let action = recording else { return }
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if modifiers.isEmpty, event.keyCode == 53 { stopRecording(); return } // Esc
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // Delete
            stopRecording()
            commit(action) { Shortcuts.set(nil, for: action) }
            return
        }
        let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        switch ShortcutRules.validate(combo, for: action, in: Shortcuts.assignments) {
        case .needsModifier:
            warnings[action] = ShortcutRules.Problem.needsModifier.message
        case .usedBy(let other):
            warnings[action] = ShortcutRules.Problem.usedBy(other).message
            stopRecording()
        case nil:
            stopRecording()
            commit(action) { Shortcuts.set(combo, for: action) }
        }
    }

    /// Applies a change and registers it; puts the previous shortcut back if macOS refuses it.
    private func commit(_ action: ShortcutAction, _ change: () -> Void) {
        let previous = AppSettings.defaults.object(forKey: action.settingsKey)
        change()
        HotKeyManager.apply()
        if HotKeyManager.failed.contains(action) {
            AppSettings.defaults.set(previous, forKey: action.settingsKey)
            HotKeyManager.apply()
            warnings[action] = "This shortcut is in use by another app."
        } else {
            warnings[action] = nil
        }
        combos = Shortcuts.assignments
    }
}

// MARK: - Speech to text

private struct DictationSpeechSection: View {
    @AppStorage(Keys.dictationProvider) private var provider = DictationConfig.defaultProvider.rawValue
    @AppStorage(Keys.dictationLanguage) private var language = ""
    @AppStorage(Keys.dictationWhisperModel) private var whisperModel = ""
    @AppStorage(Keys.dictationKeepWarm) private var keepWarm = false
    @AppStorage(Keys.language) private var callLanguage = "auto"
    @State private var model = ""

    private var kind: ProviderKind { DictationConfig.provider }

    private static let languages: [(code: String, name: String)] = [("auto", "Auto-detect"), ("it", "Italian"), ("en", "English")]

    var body: some View {
        SettingsGroup("Speech to Text", footer: footer) {
            SettingsRow("Provider") {
                Picker("Provider", selection: $provider) {
                    ForEach(ProviderKind.dictation) { Text($0.displayName).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Language") {
                Picker("Language", selection: $language) {
                    Text("Same as calls (\(LanguagePicker.displayName(callLanguage)))").tag("")
                    Divider()
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                    if !language.isEmpty, !Self.languages.contains(where: { $0.code == language }) {
                        Text(LanguagePicker.displayName(language)).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            switch kind {
            case .whisperCpp:
                SettingsRow(Text("Model"), subtitle: Text("A light model answers faster. Download more in Settings > Transcription.")) {
                    Picker("Model", selection: $whisperModel) {
                        Text("Automatic (Small or Base)").tag("")
                        ForEach(WhisperModel.catalog.filter(\.isInstalled)) { m in Text(m.name).tag(m.localURL.path) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SwitchRow(Text("Keep the model loaded"),
                          subtitle: Text("Results come faster, at the cost of some memory while dictation is on."),
                          isOn: $keepWarm)
            case .apple:
                GroupRow {
                    Text("Runs on this Mac. The speech model for the language is downloaded in Settings > Transcription.")
                        .font(PUI.Font.callout).foregroundStyle(.secondary)
                }
            default:
                SettingsRow("Model") {
                    HStack(spacing: PUI.Space.s) {
                        TextField("Model", text: $model, prompt: Text(kind.defaultModel))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
                        if !kind.modelPresets.isEmpty {
                            Menu {
                                ForEach(kind.modelPresets, id: \.self) { name in Button(name) { model = name } }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuStyle(.button)
                            .fixedSize()
                        }
                    }
                }
                CloudKeyStatusRow(kind: kind)
            }
        }
        .settingsAnchor("speech")
        .onAppear { model = AppSettings.defaults.string(forKey: Keys.dictationModel(kind)) ?? "" }
        .onChange(of: provider) { _, _ in
            model = AppSettings.defaults.string(forKey: Keys.dictationModel(kind)) ?? ""
            DictationController.shared.apply()
        }
        .onChange(of: model) { _, v in
            AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.dictationModel(kind))
        }
        .onChange(of: keepWarm) { _, _ in DictationWhisper.shared.apply() }
        .onChange(of: whisperModel) { _, _ in DictationWhisper.shared.apply() }
        .onChange(of: language) { _, _ in DictationWhisper.shared.apply() }
    }

    private var footer: String {
        kind.isCloud
            ? "Each dictation is sent to \(kind.displayName) with your own key, set up in Accounts."
            : "Each dictation is transcribed on this Mac and never leaves it."
    }
}

// MARK: - Polish

private struct DictationPolishSection: View {
    @AppStorage(Keys.dictationPolish) private var polish = false
    @AppStorage(Keys.dictationPolishProvider) private var provider = ""
    @AppStorage(Keys.dictationPolishPrompt) private var prompt = DictationPrompt.defaultPrompt
    @AppStorage(Keys.summaryProvider) private var summaryProvider = SummaryProviderKind.openAI.rawValue
    @ObservedObject private var nav = AppNavigation.shared
    @State private var model = ""
    @State private var showPrompt = false
    @StateObject private var access = ProviderAccess()

    private var kind: SummaryProviderKind { DictationConfig.polishProvider }

    var body: some View {
        SettingsGroup("Polish", footer: "Sends what you said to an AI model that fixes punctuation and removes filler words, in the language you spoke. Without it, only hesitations like “ehm” are removed.") {
            SwitchRow("Polish the text before inserting it", isOn: $polish)
            if polish {
                ProviderPicker(selection: $provider, sameAs: SummaryProviderKind(rawValue: summaryProvider) ?? .openAI)
                ModelField(kind: kind, text: $model, subtitle: "A small, fast model is enough.")
                ProviderStatusRow(access: access, modelMissing: kind.requiresModel && model.isEmpty)
                GroupRow {
                    DisclosureGroup(isExpanded: $showPrompt) {
                        VStack(alignment: .leading, spacing: PUI.Space.s) {
                            EditorField(text: $prompt, minHeight: 140)
                            HStack {
                                Text("{{text}} is what you said, {{instructions}} the instructions of the mode.")
                                    .font(PUI.Font.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset") { prompt = DictationPrompt.defaultPrompt }
                                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                                    .disabled(prompt == DictationPrompt.defaultPrompt)
                            }
                        }
                        .padding(.top, PUI.Space.s)
                    } label: {
                        HStack {
                            Text("Customize Prompt").font(PUI.Font.body)
                            Spacer()
                            Text(prompt == DictationPrompt.defaultPrompt ? "Default" : "Custom")
                                .font(PUI.Font.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .settingsAnchor("polishPrompt")
            }
        }
        .settingsAnchor("polish")
        .onAppear {
            load()
            if nav.wants(["polishPrompt"], in: .dictation) { showPrompt = true }
        }
        .onChange(of: provider) { _, _ in load() }
        .onChange(of: summaryProvider) { _, _ in load() }
        .onChange(of: model) { _, v in
            AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.dictationPolishModel(kind))
        }
    }

    private func load() {
        model = AppSettings.defaults.string(forKey: Keys.dictationPolishModel(kind)) ?? ""
        access.load(kind)
    }
}

// MARK: - Modes

private struct DictationModesSection: View {
    @AppStorage(Keys.dictationActiveMode) private var active = ""
    @State private var modes = DictationConfig.modes
    @State private var expanded: String?

    var body: some View {
        SettingsGroup("Modes", footer: "Each mode adds its own instructions to the polish prompt and can use another provider or model. The second shortcut and the dictation panel switch between them.") {
            ForEach($modes) { $mode in
                GroupRow {
                    DisclosureGroup(isExpanded: Binding(get: { expanded == mode.id },
                                                        set: { expanded = $0 ? mode.id : nil })) {
                        editor($mode)
                    } label: {
                        HStack(spacing: PUI.Space.s) {
                            Image(systemName: isActive(mode) ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(isActive(mode) ? AppAccent.kaiku.color : .secondary)
                                .onTapGesture { select(mode) }
                                .accessibilityLabel(isActive(mode) ? "Active mode" : "Make active")
                                .accessibilityAddTraits(.isButton)
                            Text(mode.name.isEmpty ? "Untitled" : mode.name).font(PUI.Font.body)
                            Spacer()
                            if isActive(mode) {
                                Text("Active").font(PUI.Font.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            GroupRow {
                HStack {
                    Button("Add Mode", action: add)
                    Spacer()
                    Button("Restore Default Modes") {
                        modes = DictationModes.defaults
                        active = DictationModes.defaults[0].id
                    }
                    .disabled(modes == DictationModes.defaults)
                }
                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            }
        }
        .settingsAnchor("modes")
        .onChange(of: modes) { _, value in
            DictationConfig.modes = value
            DictationController.shared.modesChanged()
        }
        .onChange(of: active) { _, _ in DictationController.shared.modesChanged() }
    }

    private func editor(_ mode: Binding<DictationMode>) -> some View {
        VStack(alignment: .leading, spacing: PUI.Space.s) {
            TextField("Name", text: mode.name, prompt: Text("Name"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Text("Instructions").font(PUI.Font.caption).foregroundStyle(.secondary)
            EditorField(text: mode.prompt, minHeight: 70)
            HStack(spacing: PUI.Space.s) {
                Picker("Provider", selection: Binding(get: { mode.wrappedValue.provider ?? "" },
                                                      set: { mode.wrappedValue.provider = $0.isEmpty ? nil : $0 })) {
                    Text("Polish provider").tag("")
                    Divider()
                    ForEach(SummaryProviderKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .fixedSize()
                TextField("Model", text: Binding(get: { mode.wrappedValue.model ?? "" },
                                                 set: { mode.wrappedValue.model = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Default model"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Spacer()
                Button("Delete", role: .destructive) { delete(mode.wrappedValue) }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            }
        }
        .padding(.top, PUI.Space.s)
    }

    private func isActive(_ mode: DictationMode) -> Bool { DictationModes.active(id: active, in: modes)?.id == mode.id }

    private func select(_ mode: DictationMode) { active = mode.id }

    private func add() {
        let mode = DictationMode(name: DictationModes.uniqueName("New mode", in: modes), prompt: "")
        modes.append(mode)
        expanded = mode.id
    }

    private func delete(_ mode: DictationMode) {
        modes.removeAll { $0.id == mode.id }
        if active == mode.id { active = modes.first?.id ?? "" }
    }
}

// MARK: - Insertion

private struct DictationInsertionSection: View {
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        SettingsGroup("Insertion", footer: "The text is pasted where the cursor is, then the clipboard gets back what it held. Without Accessibility the text is only copied, and you paste it with ⌘V.") {
            GroupRow {
                HStack(spacing: PUI.Space.m) {
                    if permissions.accessibilityGranted {
                        StatusDot(kind: .ok, text: "Pastes into the app you are typing in")
                    } else {
                        StatusDot(kind: .warning, text: "Accessibility is off: dictations are copied only")
                        Spacer(minLength: PUI.Space.m)
                        Button(permissions.accessibility == .notAsked ? "Allow…" : "Open Settings…") {
                            permissions.requestAccessibility()
                        }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
        }
        .settingsAnchor("insertion")
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}

// MARK: - History

private struct DictationHistorySection: View {
    @ObservedObject private var controller = DictationController.shared
    @State private var copied: String?

    var body: some View {
        SettingsGroup("Recent Dictations", footer: "The last \(DictationHistory.limit) dictations, kept on this Mac.") {
            if controller.history.isEmpty {
                GroupRow { Text("Nothing dictated yet.").font(PUI.Font.callout).foregroundStyle(.secondary) }
            }
            ForEach(controller.history) { entry in
                GroupRow {
                    HStack(alignment: .top, spacing: PUI.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text).font(PUI.Font.body).lineLimit(3).textSelection(.enabled)
                            Text(caption(entry)).font(PUI.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: PUI.Space.m)
                        Button(copied == entry.id ? "Copied" : "Copy") {
                            controller.copy(entry)
                            copied = entry.id
                        }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        Button {
                            controller.remove(entry)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove from the list")
                        .accessibilityLabel("Remove dictation")
                    }
                }
            }
            if !controller.history.isEmpty {
                GroupRow {
                    HStack {
                        Spacer()
                        Button("Clear History") { controller.clearHistory() }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
        }
        .settingsAnchor("history")
    }

    private func caption(_ entry: DictationEntry) -> String {
        let date = entry.date.formatted(date: .abbreviated, time: .shortened)
        return entry.mode.map { "\(date) · \($0)" } ?? date
    }
}
