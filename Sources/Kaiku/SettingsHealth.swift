import AppKit
import KaikuCore
import PartitiUI
import SwiftUI

/// What in the settings keeps something from working, for Needs Attention, the badges on the
/// panes and the dot on the Settings button. Checked again whenever Kaiku becomes active and
/// whenever a setting changes.
@MainActor
final class SettingsHealth: ObservableObject {
    static let shared = SettingsHealth()

    struct Issue: Identifiable, Equatable {
        enum Level: Int { case blocking, warning, info }
        let level: Level
        let text: String
        /// Where it shows, like "Summaries · Accounts".
        let detail: String
        /// The pane whose badge counts it.
        let pane: SettingsPane
        /// Where a click leads.
        let target: SettingsTarget
        var id: String { "\(pane.rawValue)|\(text)" }

        static func == (a: Issue, b: Issue) -> Bool { a.id == b.id && a.level == b.level && a.detail == b.detail }
    }

    @Published private(set) var issues: [Issue] = []
    /// Linear refused the saved key the last time it was used from Settings.
    var linearRefused = false { didSet { if linearRefused != oldValue { refresh() } } }

    private var ollamaDown = false
    private var speechModelMissing = false
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SettingsHealth.shared.refreshSoon(probe: true) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SettingsHealth.shared.refreshSoon(probe: false) }
        })
        refresh()
        probe()
    }

    /// Red when something blocks transcription, orange for any other problem; nil otherwise.
    var dotColor: Color? {
        if issues.contains(where: { $0.level == .blocking }) { return .red }
        if issues.contains(where: { $0.level == .warning }) { return .orange }
        return nil
    }

    /// Problems counted on a pane in the sidebar; information doesn't count.
    func badge(for pane: SettingsPane) -> Int {
        issues.filter { $0.pane == pane && $0.level != .info }.count
    }

    /// The first problem, to open Settings on.
    var first: Issue? { issues.first { $0.level != .info } }

    /// Settings change in bursts: checks once they settle.
    private func refreshSoon(probe: Bool) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            refresh()
            if probe { self.probe() }
        }
    }

    /// Checks what can be read right away.
    func refresh() {
        var found: [Issue] = []
        func add(_ level: Issue.Level, _ text: String, _ detail: String, _ pane: SettingsPane, _ target: SettingsTarget) {
            found.append(Issue(level: level, text: text, detail: detail, pane: pane, target: target))
        }
        let permissions = Permissions.shared

        if permissions.microphone == .denied {
            add(.blocking, "Microphone access is off", "Permissions › Microphone", .permissions, SettingsTarget(.permissions, "microphone"))
        }

        let provider = AppSettings.provider
        switch provider.readiness {
        case .needsModel where provider == .whisperCpp:
            add(.blocking, "Download a transcription model", "Transcription › Model", .transcription, SettingsTarget(.transcription, "model"))
        case .needsBinary:
            add(.blocking, "whisper-cli not found", "Transcription › Advanced", .transcription, SettingsTarget(.transcription, "advanced"))
        case .needsKey:
            if let service = AccountService.of(provider) {
                add(.blocking, "\(service.displayName) key missing", "Transcription · Accounts", .transcription,
                    SettingsTarget(.accounts, service.anchor))
            }
        default: break
        }
        if provider == .apple && speechModelMissing {
            add(.blocking, "Download the speech model", "Transcription › Model", .transcription, SettingsTarget(.transcription, "model"))
        }

        if AppSettings.summaryEnabled, let problem = problem(of: AppSettings.summaryProvider) {
            add(.warning, problem, "Summaries · Accounts", .ai, SettingsTarget(.accounts, AccountService.of(AppSettings.summaryProvider).anchor))
        }
        if AppSettings.liveAssistEnabled, let problem = problem(of: AppSettings.liveProvider) {
            add(.warning, problem, "Live Assist · Accounts", .ai, SettingsTarget(.accounts, AccountService.of(AppSettings.liveProvider).anchor))
        }
        if AppSettings.liveEnabled, let engine = AppSettings.liveEngine, let keyProvider = engine.keyProvider,
           Keychain.apiKey(for: keyProvider) == nil, let service = AccountService.of(keyProvider) {
            add(.warning, "\(service.displayName) key missing", "Live · Accounts", .transcription, SettingsTarget(.accounts, service.anchor))
        }
        if Self.chatUsed, let problem = problem(of: AppSettings.chatProvider) {
            add(.warning, problem, "Chat · Accounts", .ai, SettingsTarget(.accounts, AccountService.of(AppSettings.chatProvider).anchor))
        }

        if AppSettings.callEndMode == .ask && AppSettings.callEndBehavior != .ask {
            add(.warning, "Kaiku can't ask when a call ends", "Call Detection › Detection", .callDetection,
                SettingsTarget(.callDetection, "detection"))
        }
        if AppSettings.calendarEnabled && permissions.calendar == .denied {
            add(.warning, "Calendar access is off", "Call Detection › Calendar", .callDetection, SettingsTarget(.callDetection, "calendar"))
        }
        if AppSettings.detectCalls && AppSettings.autoRecordMode != .off && !permissions.accessibilityGranted {
            add(.warning, "Web calls can't be told apart", "Permissions › Accessibility", .callDetection,
                SettingsTarget(.permissions, "accessibility"))
        }
        if AppSettings.webhookEnabled && !Self.isValidWebhookURL(AppSettings.webhookURL) {
            add(.warning, "Webhook address is incomplete", "Integrations › Webhook", .integrations, SettingsTarget(.integrations, "webhook"))
        }
        if !(AppSettings.defaults.string(forKey: Keys.remindersListID) ?? "").isEmpty && RemindersService.shared.state != .granted {
            add(.warning, "Reminders access is off", "Permissions › Reminders", .integrations, SettingsTarget(.permissions, "reminders"))
        }
        if linearRefused && LinearAPI.key != nil {
            add(.warning, "Linear key was refused", "Accounts › Linear", .accounts, SettingsTarget(.accounts, AccountService.linear.anchor))
        }
        for service in AccountService.allCases where service.keychainError != nil {
            add(.warning, "Couldn't read the \(service.displayName) key", "Accounts", .accounts, SettingsTarget(.accounts, service.anchor))
        }
        if LoginItem.needsApproval {
            add(.warning, "Approve Kaiku in Login Items", "General › Startup", .general, SettingsTarget(.general, "startup"))
        }

        if permissions.notifications == .denied {
            add(.info, "Notifications are off", "Notifications", .notifications, SettingsTarget(.notifications, "system"))
        }
        let rules = AppSettings.sourceRules
        let newSources = AppSettings.seenSources.filter { rules.rule(for: $0) == .new && !AppSettings.removedSources.contains($0) }.count
        if newSources > 0 {
            add(.info, "\(newSources) new source\(newSources == 1 ? "" : "s") to review", "Call Detection › Sources", .callDetection,
                SettingsTarget(.callDetection, "sources"))
        }

        found.sort { $0.level.rawValue < $1.level.rawValue }
        if found != issues { issues = found }
    }

    /// What keeps an AI provider from answering, in a few words; nil when it's ready.
    private func problem(of kind: SummaryProviderKind) -> String? {
        if kind == .ollama { return ollamaDown ? "Ollama isn't running" : nil }
        guard kind.problem != nil else { return nil }
        if kind.cli != nil { return "\(kind.displayName) not found" }
        if kind == .custom { return "Custom server address missing" }
        return "\(kind.displayName) key missing"
    }

    /// Checks that need a moment: the Ollama server and the system speech model.
    private func probe() {
        let usesOllama = (AppSettings.summaryEnabled && AppSettings.summaryProvider == .ollama)
            || (AppSettings.liveAssistEnabled && AppSettings.liveProvider == .ollama)
            || (Self.chatUsed && AppSettings.chatProvider == .ollama)
        let checksSpeech = AppSettings.provider == .apple && TranscriptionSettings.previewSpeechReadiness == nil
        Task {
            if usesOllama, let url = SummaryProviderKind.ollama.probeURL {
                let up = (try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 3)))?.1 is HTTPURLResponse
                ollamaDown = !up
            } else {
                ollamaDown = false
            }
            if checksSpeech {
                let readiness = await LiveEngineKind.apple.readiness(language: AppSettings.language)
                if case .needsDownload = readiness { speechModelMissing = true } else { speechModelMissing = false }
            } else {
                speechModelMissing = false
            }
            refresh()
        }
    }

    /// Chats were saved, so the chat provider matters.
    private static var chatUsed: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: AppSettings.chatsFolder.path)) ?? []
        return files.contains { $0.hasSuffix(".json") }
    }

    static func isValidWebhookURL(_ raw: String) -> Bool {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespaces)), let s = u.scheme?.lowercased() else { return false }
        return (s == "http" || s == "https") && u.host != nil
    }
}
