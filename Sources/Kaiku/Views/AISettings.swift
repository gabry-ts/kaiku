import AppKit
import KaikuCore
import PartitiUI
import SwiftUI

/// Settings > AI: summaries, help during calls and chat, and the model behind each.
/// Keys, servers and tools are set up in Accounts; here only the provider and model are chosen.
struct AISettings: View {
    var body: some View {
        KaikuPane(pane: .ai, subtitle: "Summaries, help during calls, and chat, and the model behind each.") {
            if !Self.anyProviderReady {
                SettingsGroup {
                    GroupRow {
                        HStack(spacing: PUI.Space.m) {
                            Image(systemName: "sparkles").foregroundStyle(AppAccent.kaiku.color)
                            Text("Connect a provider to summarize and chat with your calls. Ollama and Claude Code need no API key.")
                                .font(PUI.Font.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: PUI.Space.l)
                            Button("Set Up a Provider…") { WindowManager.shared.showSettings(.accounts) }
                                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        }
                    }
                }
            }
            SummariesSection()
            LiveAssistSection()
            ChatSection()
        }
    }

    /// True when some provider has its key, server address or tool. Ollama counts once chosen.
    static var anyProviderReady: Bool {
        let chosen = [AppSettings.summaryProvider, AppSettings.liveProvider, AppSettings.chatProvider]
        return SummaryProviderKind.allCases.contains { $0 != .ollama && $0.problem == nil } || chosen.contains(.ollama)
    }
}

// MARK: - Summaries

private struct SummariesSection: View {
    @AppStorage(Keys.summaryEnabled) private var enabled = false
    @AppStorage(Keys.summaryProvider) private var provider = SummaryProviderKind.openAI.rawValue
    @AppStorage(Keys.summaryPrompt) private var prompt = SummaryAPI.defaultPrompt
    @ObservedObject private var nav = AppNavigation.shared
    @State private var model = ""
    @State private var showPrompt = false
    @State private var confirmReset = false
    @StateObject private var access = ProviderAccess()

    private var kind: SummaryProviderKind { SummaryProviderKind(rawValue: provider) ?? .openAI }

    var body: some View {
        SettingsGroup("Summaries", footer: "Saves summary.md in the call folder, with the call's action items. You can also summarize any call by hand.") {
            SwitchRow("Summarize every call after transcription", isOn: $enabled)
                .settingsAnchor("summarize")
            ProviderPicker(selection: $provider)
                .settingsAnchor("summaryProvider")
            ModelField(kind: kind, text: $model)
            ProviderStatusRow(access: access, modelMissing: kind.requiresModel && model.isEmpty)
            GroupRow {
                DisclosureGroup(isExpanded: $showPrompt) {
                    VStack(alignment: .leading, spacing: PUI.Space.s) {
                        EditorField(text: $prompt, minHeight: 140)
                        HStack {
                            Text("{{title}} and {{transcript}} are filled in.").font(PUI.Font.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset…") { confirmReset = true }
                                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                                .disabled(prompt == SummaryAPI.defaultPrompt)
                        }
                    }
                    .padding(.top, PUI.Space.s)
                } label: {
                    HStack {
                        Text("Customize Prompt").font(PUI.Font.body)
                        Spacer()
                        Text(prompt == SummaryAPI.defaultPrompt ? "Default" : "Custom")
                            .font(PUI.Font.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .settingsAnchor("summaryPrompt")
        }
        .settingsAnchor("summaries")
        .confirmationDialog("Reset the summary prompt?", isPresented: $confirmReset) {
            Button("Reset Prompt", role: .destructive) { prompt = SummaryAPI.defaultPrompt }
        } message: {
            Text("Your changes to the prompt are lost.")
        }
        .onAppear {
            load()
            if nav.wants(["summaryPrompt"], in: .ai) { showPrompt = true }
        }
        .onChange(of: nav.request) { _, _ in if nav.wants(["summaryPrompt"], in: .ai) { showPrompt = true } }
        .onChange(of: provider) { _, _ in load() }
        .onChange(of: model) { _, v in AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.summaryModel(kind)) }
    }

    private func load() {
        model = AppSettings.summaryModel(for: kind)
        access.load(kind)
    }
}

// MARK: - Live Assist

private struct LiveAssistSection: View {
    @AppStorage(Keys.liveEnabled) private var liveEnabled = false
    @AppStorage(Keys.liveAssistEnabled) private var assist = false
    @AppStorage(Keys.summaryProvider) private var summaryProvider = SummaryProviderKind.openAI.rawValue
    @AppStorage(Keys.liveProvider) private var liveProvider = ""
    @State private var summaryModel = ""
    @State private var askModel = ""
    @StateObject private var access = ProviderAccess()

    private var summaryKind: SummaryProviderKind { SummaryProviderKind(rawValue: summaryProvider) ?? .openAI }
    private var kind: SummaryProviderKind { SummaryProviderKind(rawValue: liveProvider) ?? summaryKind }

    /// Live transcription runs, so the assistant has something to read.
    private var available: Bool { LiveTranscription.isSupported && liveEnabled }

    var body: some View {
        SettingsGroup("Live Assist", footer: "Sends the live transcript to this provider while you talk. Saved as live-summary.md.") {
            if !LiveTranscription.isSupported {
                GroupRow { StatusDot(kind: .neutral, text: "Needs live transcription, which needs macOS 26.") }
            } else if !liveEnabled {
                GroupRow {
                    HStack {
                        StatusDot(kind: .neutral, text: "Needs live transcription, which is off.")
                        Spacer(minLength: PUI.Space.m)
                        Button("Turn On…") { WindowManager.shared.showSettings(.live) }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
            SwitchRow("Summarize and answer questions during calls", isOn: $assist)
                .disabled(!available)
                .opacity(available ? 1 : 0.5)
            if assist && available {
                ProviderPicker(selection: $liveProvider, sameAs: summaryKind)
                ModelField(kind: kind, text: $summaryModel, title: "Summary model", subtitle: "Refreshes about every minute.")
                ModelField(kind: kind, text: $askModel, title: "Ask model",
                           subtitle: kind.cli == nil ? "A fast model keeps answers quick." : "Slower with a command-line tool.")
                ProviderStatusRow(access: access, modelMissing: kind.requiresModel && (summaryModel.isEmpty || askModel.isEmpty))
            }
        }
        .settingsAnchor("liveAssist")
        .onAppear(perform: load)
        .onChange(of: summaryProvider) { _, _ in load() }
        .onChange(of: liveProvider) { _, _ in load() }
        .onChange(of: summaryModel) { _, v in
            AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.liveSummaryModel(kind))
        }
        .onChange(of: askModel) { _, v in
            AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.liveAskModel(kind))
        }
    }

    private func load() {
        summaryModel = AppSettings.liveSummaryModel(for: kind)
        askModel = AppSettings.liveAskModel(for: kind)
        access.load(kind)
    }
}

// MARK: - Chat

/// Who answers questions about calls in the library.
private struct ChatSection: View {
    @AppStorage(Keys.summaryProvider) private var summaryProvider = SummaryProviderKind.openAI.rawValue
    @AppStorage(Keys.chatProvider) private var chatProvider = ""
    @State private var model = ""
    @StateObject private var access = ProviderAccess()

    private var summaryKind: SummaryProviderKind { SummaryProviderKind(rawValue: summaryProvider) ?? .openAI }
    private var kind: SummaryProviderKind { SummaryProviderKind(rawValue: chatProvider) ?? summaryKind }

    var body: some View {
        SettingsGroup("Chat", footer: "Each question sends the calls in the chat to this provider. Chats stay on this Mac.") {
            ProviderPicker(selection: $chatProvider, sameAs: summaryKind)
            ModelField(kind: kind, text: $model,
                       subtitle: kind.cli == nil ? "Answers appear as they are written." : "Reads the calls first, so the answer takes a little longer.")
            ProviderStatusRow(access: access, modelMissing: kind.requiresModel && model.isEmpty)
            SettingsRow(Text("Saved chats"), subtitle: Text(AppSettings.baseFolderDisplayPath + "/Chats")) {
                Button("Show in Finder", action: showFolder)
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            }
            .settingsAnchor("savedChats")
        }
        .settingsAnchor("chat")
        .onAppear(perform: load)
        .onChange(of: summaryProvider) { _, _ in load() }
        .onChange(of: chatProvider) { _, _ in load() }
        .onChange(of: model) { _, v in
            AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.chatModel(kind))
        }
    }

    private func load() {
        model = AppSettings.chatModel(for: kind)
        access.load(kind)
    }

    private func showFolder() {
        let folder = AppSettings.chatsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

// MARK: - Provider picker

/// Chooses a provider: the ready ones first, then the ones not set up yet, then a way to
/// set one up. With `sameAs`, an empty selection follows the summaries' provider.
private struct ProviderPicker: View {
    @Binding var selection: String
    var sameAs: SummaryProviderKind?

    private static let setUp = "__setup"

    var body: some View {
        let ready = SummaryProviderKind.allCases.filter { $0.problem == nil }
        let others = SummaryProviderKind.allCases.filter { $0.problem != nil }
        SettingsRow("Provider") {
            Picker("Provider", selection: Binding(get: { current }, set: { value in
                if value == Self.setUp {
                    WindowManager.shared.showSettings(.accounts)
                } else {
                    selection = value
                }
            })) {
                if let sameAs {
                    Text("Same as Summaries (\(sameAs.displayName))").tag("")
                    Divider()
                }
                Section("Ready") {
                    ForEach(ready) { Text(label(for: $0)).tag($0.rawValue) }
                }
                Section("Not set up") {
                    ForEach(others) { Text($0.displayName).tag($0.rawValue) }
                }
                Divider()
                Text("Set Up a Provider…").tag(Self.setUp)
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// The saved value, or the summaries' provider when this one follows it.
    private var current: String {
        if sameAs != nil { return SummaryProviderKind(rawValue: selection)?.rawValue ?? "" }
        return SummaryProviderKind(rawValue: selection)?.rawValue ?? SummaryProviderKind.openAI.rawValue
    }

    private func label(for kind: SummaryProviderKind) -> String {
        if kind.cli != nil { return "\(kind.displayName) · your sign-in" }
        if kind == .ollama { return "Ollama · on this Mac" }
        return kind.displayName
    }
}
