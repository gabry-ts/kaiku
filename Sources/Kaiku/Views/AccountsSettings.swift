import AppKit
import KaikuCore
import PartitiUI
import SwiftUI

/// Settings > Accounts: every API key, server address and command-line tool, entered once.
/// Each service is a row that opens to its fields; links from other panes open it directly.
struct AccountsSettings: View {
    @ObservedObject private var nav = AppNavigation.shared
    @AppStorage(Keys.summaryEnabled) private var summaryEnabled = false
    @State private var expanded: Set<AccountService> = []
    /// Bumped when something was saved, so statuses and "Used by" are read again.
    @State private var version = 0
    /// The first AI service just set up, offered for summaries.
    @State private var suggestion: AccountService?

    var body: some View {
        KaikuPane(pane: .accounts, subtitle: "API keys, local servers and command-line tools, entered once.") {
            if let suggestion, let kind = suggestion.summaryKind {
                SettingsGroup {
                    GroupRow {
                        HStack(spacing: PUI.Space.m) {
                            Image(systemName: "sparkles").foregroundStyle(AppAccent.kaiku.color)
                            Text("Summarize every call with \(suggestion.displayName)?").font(PUI.Font.body)
                            Spacer(minLength: PUI.Space.l)
                            Button("Not Now") { self.suggestion = nil }
                                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                            Button("Turn On") {
                                AppSettings.defaults.set(kind.rawValue, forKey: Keys.summaryProvider)
                                summaryEnabled = true
                                self.suggestion = nil
                                version += 1
                            }
                            .buttonStyle(PrimaryButtonStyle(height: PUI.Control.small, fullWidth: false))
                        }
                    }
                }
            }

            group("Cloud Services", .cloud, footer: "Kaiku works fully on this Mac without any of these. Keys are saved in your Keychain.")
                .settingsAnchor("cloud")
            group("On Your Network", .network, footer: "Ollama, LM Studio or any server that speaks the OpenAI API. Nothing leaves your Mac while it runs here.")
                .settingsAnchor("network")
            group("Command-Line Tools", .cli, footer: "Uses your own sign-in, no API key.")
                .settingsAnchor("cli")
            group("Apps", .apps, footer: nil)
                .settingsAnchor("apps")
        }
        .onAppear(perform: openRequested)
        .onChange(of: nav.request) { _, _ in openRequested() }
    }

    private func group(_ title: String, _ group: AccountService.Group, footer: String?) -> some View {
        SettingsGroup(title, footer: footer) {
            ForEach(AccountService.all(in: group)) { service in
                AccountRow(service: service, version: version,
                           expanded: Binding(get: { expanded.contains(service) },
                                             set: { if $0 { expanded.insert(service) } else { expanded.remove(service) } }),
                           saved: { saved(service, wasSetUp: $0) })
                    .settingsAnchor(service.anchor)
            }
        }
    }

    /// Opens the row a link asked for.
    private func openRequested() {
        for service in AccountService.allCases where nav.wants([service.anchor], in: .accounts) {
            expanded.insert(service)
        }
    }

    /// After a save: offers summaries when this is the first AI service set up.
    private func saved(_ service: AccountService, wasSetUp: Bool) {
        version += 1
        guard !wasSetUp, service.isSetUp, !summaryEnabled, service.summaryKind != nil else { return }
        let others = AccountService.allCases.filter { $0 != service && $0 != .ollama && $0.summaryKind != nil }
        if !others.contains(where: \.isSetUp) { suggestion = service }
    }
}

/// One service: tile, name, what uses it and its state; opens to its fields.
private struct AccountRow: View {
    let service: AccountService
    let version: Int
    @Binding var expanded: Bool
    /// Called after a change, with whether the service was set up before it.
    let saved: (Bool) -> Void
    @State private var running: Bool?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: PUI.Space.m + 2) {
                    LetterTile(service: service)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.displayName).font(PUI.Font.body).foregroundStyle(ink.primary)
                        Text(caption).font(PUI.Font.caption).foregroundStyle(ink.secondary).lineLimit(1)
                    }
                    Spacer(minLength: PUI.Space.l)
                    status(ink)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ink.tertiary)
                        .frame(width: 12)
                }
                .padding(.horizontal, PUI.Space.l)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(service.displayName), \(statusText)")
            .accessibilityHint(expanded ? "Hides the settings" : "Shows the settings")

            if expanded {
                AccountFields(service: service, saved: { wasSetUp in
                    saved(wasSetUp)
                    Task { await probe() }
                })
                .padding(.leading, PUI.Space.l + 26 + PUI.Space.m + 2)
                .padding(.trailing, PUI.Space.l)
                .padding(.bottom, PUI.Space.l)
            }
        }
        .task(id: version) { await probe() }
    }

    private var caption: String {
        _ = version
        var parts = [service.usedBy.isEmpty ? "Not used" : "Used by " + service.usedBy.joined(separator: " · ")]
        if service.group == .network {
            let kind = service.summaryKind ?? .ollama
            let address = kind.baseURL.isEmpty ? (service == .ollama ? LocalLLM.ollamaDefaultBase : "") : kind.baseURL
            if !address.isEmpty { parts.append(address) }
        }
        return parts.joined(separator: " · ")
    }

    private enum Condition { case ready, notSetUp, problem }

    private var state: Condition {
        _ = version
        if service.keychainError != nil { return .problem }
        switch service {
        case .ollama:
            return running == false ? .problem : .ready
        case .custom:
            guard service.isSetUp else { return .notSetUp }
            return running == false ? .problem : .ready
        default:
            return service.isSetUp ? .ready : .notSetUp
        }
    }

    private var statusText: String {
        if service.keychainError != nil { return "Keychain error" }
        switch (service.group, state) {
        case (.network, .ready): return running == nil ? "Checking…" : "Running"
        case (.network, .problem): return "Not running"
        case (.cli, .ready): return "Found"
        case (.cli, _): return "Not found"
        case (_, .ready): return "Ready"
        default: return "Not set up"
        }
    }

    private func status(_ ink: Ink) -> some View {
        let color: Color = switch state {
        case .ready: ink.green
        case .problem: service.keychainError != nil ? ink.red : ink.orange
        case .notSetUp: service.usedBy.isEmpty ? ink.tertiary : ink.orange
        }
        return HStack(spacing: PUI.Space.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(statusText).font(PUI.Font.callout).foregroundStyle(ink.secondary)
        }
    }

    /// Whether the server answers, for the services on the network.
    private func probe() async {
        guard service.group == .network, let url = service.summaryKind?.probeURL else { running = nil; return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        if let key = service.key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        // Any HTTP answer, even a refusal, means something is listening.
        let up = (try? await URLSession.shared.data(for: req))?.1 is HTTPURLResponse
        guard !Task.isCancelled else { return }
        running = up
    }
}

/// The fields of an open service row.
private struct AccountFields: View {
    let service: AccountService
    let saved: (Bool) -> Void
    @AppStorage(Keys.alibabaRegion) private var alibabaRegion = AlibabaRegion.singapore.rawValue
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: PUI.Space.m) {
            if service == .alibaba {
                FieldLine("Region", subtitle: "The key must belong to this region.") {
                    Picker("Region", selection: $alibabaRegion) {
                        ForEach(AlibabaRegion.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let kind = service.summaryKind, kind.isLocal {
                AddressField(kind: kind, saved: { saved(service.isSetUp) })
            }
            if service.keyAccount != nil {
                KeyField(service: service, saved: saved)
            }
            if let cli = service.cli {
                CLIPathField(tool: cli, saved: { saved(false) })
            }
            if KeyTester.canTest(service) || service == .alibaba {
                HStack(spacing: PUI.Space.m) {
                    if service == .alibaba {
                        Text("Check the key with Test Alibaba Cloud in Transcription.")
                            .font(PUI.Font.caption).foregroundStyle(.secondary)
                    } else {
                        Button(service.group == .network ? "Check" : "Test Key") {
                            testing = true
                            result = nil
                            Task {
                                let r = await KeyTester.test(service)
                                result = r
                                testing = false
                                if service == .linear { SettingsHealth.shared.linearRefused = !r.ok && service.key != nil }
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        .disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        if let result {
                            StatusDot(kind: result.ok ? .ok : .error, text: result.message)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A label on the left and its control, inside an open service row.
private struct FieldLine<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let control: Control

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PUI.Space.l) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PUI.Font.callout).foregroundStyle(.secondary)
                if let subtitle { Text(subtitle).font(PUI.Font.caption).foregroundStyle(.tertiary) }
            }
            .frame(width: 120, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
    }
}

/// The API key, saved in the Keychain when you press Return or leave the field.
private struct KeyField: View {
    let service: AccountService
    let saved: (Bool) -> Void
    @State private var text = ""
    @State private var reveal = false
    @State private var justSaved = false
    @State private var confirmRemove = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PUI.Space.s) {
            FieldLine(service == .custom ? "API key (optional)" : "API key") {
                HStack(spacing: PUI.Space.s) {
                    Group {
                        if reveal {
                            TextField("API key", text: $text, prompt: Text(service.keyPlaceholder))
                        } else {
                            SecureField("API key", text: $text, prompt: Text(service.keyPlaceholder))
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(maxWidth: 320)
                    .focused($focused)
                    .onSubmit(save)
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(reveal ? "Hide key" : "Show key")
                        .accessibilityLabel(reveal ? "Hide key" : "Show key")
                }
            }
            HStack(spacing: PUI.Space.m) {
                Spacer().frame(width: 120)
                if let error = service.keychainError {
                    StatusDot(kind: .error, text: error)
                } else {
                    Label(justSaved ? "Saved in your Keychain" : "Kept in your Keychain", systemImage: "lock.fill")
                        .font(PUI.Font.caption).foregroundStyle(.secondary)
                }
                if let url = service.keyURL {
                    Link("Get an API key", destination: url).font(PUI.Font.caption)
                }
                Spacer(minLength: 0)
                if service.key != nil {
                    Button("Remove Key…") { confirmRemove = true }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
            }
        }
        .onAppear {
            text = service.keyAccount.flatMap { Keychain.get($0) } ?? ""
            if service.key == nil { focused = true }
        }
        .onChange(of: focused) { _, f in if !f { save() } }
        .onDisappear(perform: save)
        .confirmationDialog("Remove the \(service.displayName) key?", isPresented: $confirmRemove) {
            Button("Remove Key", role: .destructive) {
                guard let account = service.keyAccount else { return }
                let had = service.isSetUp
                Keychain.set("", for: account)
                text = ""
                saved(had)
            }
        } message: {
            Text("Kaiku can't use \(service.displayName) until you add a key again.")
        }
    }

    private func save() {
        guard let account = service.keyAccount else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (service.key ?? "") else { return }
        let had = service.isSetUp
        if Keychain.set(value, for: account) {
            justSaved = !value.isEmpty
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                justSaved = false
            }
        }
        saved(had)
    }
}

/// Address of Ollama or of an OpenAI-compatible server.
private struct AddressField: View {
    let kind: SummaryProviderKind
    let saved: () -> Void
    @State private var text = ""

    var body: some View {
        FieldLine("Server address") {
            TextField("Server address", text: $text, prompt: Text(kind.baseURLPlaceholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(maxWidth: 320)
                .onSubmit(save)
        }
        .onAppear { text = AppSettings.defaults.string(forKey: Keys.baseURL(kind)) ?? "" }
        .onChange(of: text) { _, _ in save() }
    }

    private func save() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value != (AppSettings.defaults.string(forKey: Keys.baseURL(kind)) ?? "") else { return }
        AppSettings.defaults.set(value, forKey: Keys.baseURL(kind))
        saved()
    }
}

/// Path of a command-line tool; empty finds it by itself.
private struct CLIPathField: View {
    let tool: CLITool
    let saved: () -> Void
    @State private var path = ""
    @State private var found: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PUI.Space.s) {
            PathField(label: tool.binaryName, path: $path, placeholder: "Automatic", fallback: found) {
                CLIProviders.forget(tool)
                path = ""
                Task { await refresh() }
            }
            .padding(.horizontal, -PUI.Space.l)
            if let found {
                StatusDot(kind: .ok, text: "Found at \(found)")
            } else {
                StatusDot(kind: .warning, text: "Not found. Install it, or set its path.")
            }
        }
        .onAppear {
            path = AppSettings.defaults.string(forKey: Keys.cliPath(tool)) ?? ""
            Task { await refresh() }
        }
        .onChange(of: path) { _, v in
            AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.cliPath(tool))
            found = CLIProviders.locate(tool)
            saved()
        }
    }

    private func refresh() async {
        found = await CLIProviders.detect(tool)
        saved()
    }
}

/// A colored tile with the service's initial, like an app icon.
private struct LetterTile: View {
    let service: AccountService

    var body: some View {
        RoundedRectangle(cornerRadius: PUI.Radius.tile(26), style: .continuous)
            .fill(color.gradient)
            .frame(width: 26, height: 26)
            .overlay {
                Text(String(service.displayName.prefix(1)))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch service {
        case .openAI: return .teal
        case .anthropic: return .brown
        case .groq: return .orange
        case .openRouter: return .indigo
        case .elevenLabs: return Color(white: 0.25)
        case .alibaba: return .red
        case .ollama: return Color(white: 0.15)
        case .custom: return .gray
        case .claudeCode: return .orange
        case .codex: return .blue
        case .opencode: return .purple
        case .linear: return Color(red: 0.37, green: 0.42, blue: 0.82)
        }
    }
}
