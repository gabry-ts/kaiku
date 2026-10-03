import AppKit
import PartitiUI
import SwiftUI
import UniformTypeIdentifiers
import KaikuCore

/// Settings > Call Detection: when Kaiku notices a call, what it records by itself, its sources
/// and the calendar that names calls.
struct CallDetectionSettings: View {
    var body: some View {
        KaikuPane(pane: .callDetection, subtitle: "When Kaiku notices a call, what it records by itself, and how it names it.") {
            DetectionSection()
            SourcesSection()
            CalendarSection()
        }
    }
}

/// Which apps and websites can start a recording, and which of them record by themselves
/// (depending on the automatic recording mode). A source never decided is marked New and
/// asked about the first time. Apps can be added from the Finder, websites by words in their window title,
/// and any source removed from the list; one added by hand asks first.
private struct SourcesSection: View {
    @State private var rules = SourceRules()
    @State private var custom: [CustomApp] = []
    @State private var sites: [CustomWebsite] = []
    @State private var addingWebsite = false
    @State private var removed: [String] = []
    @State private var sources: [String] = []
    @State private var message: String?
    @State private var confirmRemove: String?
    @AppStorage(Keys.autoRecordMode) private var modeRaw = AutoRecordMode.off.rawValue
    @AppStorage(Keys.detectCalls) private var detect = true
    @ObservedObject private var permissions = Permissions.shared

    private var mode: AutoRecordMode { AutoRecordMode(rawValue: modeRaw) ?? .off }

    /// Web calls are told apart by the browser window title, which needs Accessibility.
    private var needsAccessibility: Bool {
        !permissions.accessibilityGranted && sources.contains { source in
            sites.contains { $0.name == source } || CallSource.known.first { $0.name == source }.map { !$0.titleKeywords.isEmpty } == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PUI.Space.xl + 2) {
            sourcesGroup
            removedGroup
        }
        .confirmationDialog("Remove \(confirmRemove ?? "")?", isPresented: Binding(get: { confirmRemove != nil },
                                                                                 set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let source = confirmRemove { remove(source) }
                confirmRemove = nil
            }
        } message: {
            Text(sites.contains { $0.name == confirmRemove } ? "Its title words will be lost." : "You can add it again later.")
        }
        .onAppear(perform: load)
        // A rule set from a notification ("Never") or a newly seen source while this is open.
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.sourcesChanged)) { _ in load() }
        .sheet(isPresented: $addingWebsite) {
            AddWebsiteSheet(existing: sources + removed) { site in addWebsite(site) }
                .puiAccent(.kaiku)
        }
    }

    private var sourcesGroup: some View {
        SettingsGroup("Sources", footer: "An app and its website count as one source, like WhatsApp and WhatsApp Web.") {
            if !detect {
                GroupRow { StatusDot(kind: .neutral, text: "Call detection is off.") }
            }
            if sources.isEmpty {
                GroupRow {
                    Text("No calls detected yet. Sources appear after your first call, or add one.")
                        .font(PUI.Font.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(sources, id: \.self) { source in
                GroupRow {
                    HStack(spacing: PUI.Space.m + 2) {
                        SourceIcon(source: source, custom: custom)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: PUI.Space.s) {
                                Text(source).font(PUI.Font.body)
                                if rules.rule(for: source) == .new { Badge("New") }
                            }
                            Text(kind(of: source)).font(PUI.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: PUI.Space.l)
                        Picker(source, selection: Binding(
                            get: { choice(for: source) },
                            set: { apply($0, to: source) })) {
                            ForEach(choices, id: \.self) { Text($0.title(in: mode)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button { askToRemove(source) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(source)")
                        .accessibilityLabel("Remove \(source)")
                    }
                }
                .disabled(!detect)
            }
            if needsAccessibility {
                GroupRow {
                    HStack(spacing: PUI.Space.m) {
                        StatusDot(kind: .warning, text: "Web calls can't be told apart without Accessibility.")
                        Spacer(minLength: PUI.Space.m)
                        Button(permissions.accessibility == .notAsked ? "Allow…" : "Open Settings…") { permissions.requestAccessibility() }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
            GroupRow {
                HStack(spacing: PUI.Space.m) {
                    Menu {
                        Button("App…") { addApp() }
                        Button("Website…") { message = nil; addingWebsite = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .fixedSize()
                    if let message {
                        Text(message).font(PUI.Font.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!detect)
        }
        .settingsAnchor("sources")
    }

    @ViewBuilder private var removedGroup: some View {
        if !removed.isEmpty {
            SettingsGroup("Removed", footer: "Removed sources are ignored.") {
                ForEach(removed, id: \.self) { source in
                    SettingsRow(source) {
                        Button("Restore") { restore(source) }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
            .settingsAnchor("removed")
        }
    }

    /// Sources added by hand are gone for good once removed, so they ask first.
    private func askToRemove(_ source: String) {
        if custom.contains(where: { $0.name == source }) || sites.contains(where: { $0.name == source }) {
            confirmRemove = source
        } else {
            remove(source)
        }
    }

    /// What a source does when its call starts.
    private enum Choice: Hashable {
        case record, offer, ignore

        func title(in mode: AutoRecordMode) -> String {
            switch self {
            case .record: return mode == .selected ? "Record automatically" : "Record"
            case .offer: return "Offer to record"
            case .ignore: return "Ignore"
            }
        }
    }

    /// The options that make sense in the current mode.
    private var choices: [Choice] {
        switch mode {
        case .selected: return [.record, .offer, .ignore]
        case .all: return [.record, .ignore]
        case .off: return [.offer, .ignore]
        }
    }

    private func choice(for source: String) -> Choice {
        let rule = rules.rule(for: source)
        if rule == .never { return .ignore }
        switch mode {
        case .off: return .offer
        case .all: return .record
        case .selected: return rule == .always && rules.autoRecords(source) ? .record : .offer
        }
    }

    private func apply(_ choice: Choice, to source: String) {
        switch choice {
        case .record:
            rules.set(.always, for: source)
            rules.setAutoRecord(true, for: source)
        case .offer:
            rules.set(.always, for: source)
            if mode == .selected { rules.setAutoRecord(false, for: source) }
        case .ignore:
            rules.set(.never, for: source)
            rules.setAutoRecord(false, for: source)
        }
        save()
    }

    private func kind(of source: String) -> String {
        if custom.contains(where: { $0.name == source }) { return "Added app" }
        if let site = sites.first(where: { $0.name == source }) {
            return "Added website · title contains " + site.source.titleKeywords.map { "“\($0)”" }.joined(separator: " or ")
        }
        guard let known = CallSource.known.first(where: { $0.name == source }) else { return "Web page" }
        switch (known.bundlePrefixes.isEmpty, known.titleKeywords.isEmpty) {
        case (false, false): return "App and web"
        case (false, true): return "App"
        default: return "Web"
        }
    }

    private func load() {
        rules = AppSettings.sourceRules
        custom = AppSettings.customApps
        sites = AppSettings.customWebsites
        removed = AppSettings.removedSources
        refresh()
    }

    private func refresh() {
        sources = rules.listed(seen: AppSettings.seenSources, custom: custom, sites: sites, removed: removed)
    }

    private func save() {
        AppSettings.customApps = custom
        AppSettings.customWebsites = sites
        AppSettings.removedSources = removed
        // Last: it reloads this pane, which must find everything else already saved.
        AppSettings.sourceRules = rules
        refresh()
    }

    /// Added apps and websites disappear; any other source moves to Removed and is ignored.
    private func remove(_ source: String) {
        message = nil
        if let i = custom.firstIndex(where: { $0.name == source }) {
            custom.remove(at: i)
            rules.forget(source)
        } else if let i = sites.firstIndex(where: { $0.name == source }) {
            sites.remove(at: i)
            rules.forget(source)
        } else {
            rules.set(.never, for: source)
            removed.append(source)
        }
        save()
    }

    private func restore(_ source: String) {
        removed.removeAll { $0.caseInsensitiveCompare(source) == .orderedSame }
        rules.forget(source)
        save()
    }

    private func addWebsite(_ site: CustomWebsite) {
        sites.append(site)
        removed.removeAll { $0.caseInsensitiveCompare(site.name) == .orderedSame }
        rules.set(.always, for: site.name)
        save()
    }

    private func addApp() {
        message = nil
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Add"
        panel.message = "Choose an app that makes calls."
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let target: String
        switch CustomApp.adding(bundleID: bundleID, name: name, to: custom) {
        case .add(let app):
            custom.append(app)
            target = app.name
        case .existing(let existing):
            target = existing
            message = "\(existing) is already a source."
        case .browser(let browser):
            message = "\(browser) is a browser: its calls are told apart by window title."
            return
        }
        removed.removeAll { $0.caseInsensitiveCompare(target) == .orderedSame }
        rules.set(.always, for: target)
        save()
    }
}

// MARK: - Detection

/// When a call is noticed, what records by itself, and when a recording stops after the call.
private struct DetectionSection: View {
    @AppStorage(Keys.detectCalls) private var detect = true
    @AppStorage(Keys.autoRecordMode) private var autoRecord = AutoRecordMode.off.rawValue
    @AppStorage(Keys.detectAutoStopSeconds) private var autoStop = 120
    @AppStorage(Keys.detectCallEndMode) private var callEnd = CallEndMode.standard.rawValue
    @AppStorage(NotificationKind.callEnded.showKey) private var callEndedShown = true
    @ObservedObject private var permissions = Permissions.shared

    private var mode: CallEndMode { CallEndMode(saved: callEnd) }
    private var behavior: CallEndBehavior {
        mode.behavior(notificationsAllowed: permissions.notificationsAllowed, callEndedNotificationEnabled: callEndedShown)
    }
    /// Ask every time was chosen, but the question can't be shown.
    private var fallsBack: Bool { mode == .ask && behavior != .ask }

    private var fallbackNote: String {
        let why = permissions.notificationsAllowed
            ? "The Call ended notification is off"
            : "macOS doesn't allow notifications from Kaiku"
        let then = autoStop > 0
            ? "the recording stops after the delay instead."
            : "the recording goes on until you stop it."
        return "\(why), so Kaiku can't ask: \(then)"
    }

    private var modeDetail: String {
        switch mode {
        case .stopAfterDelay: return "A notification lets you stop right away; otherwise the recording stops after the delay."
        case .ask: return "A notification asks whether to stop. The recording goes on until you answer."
        case .nothing: return "No notification. The recording goes on until you stop it."
        }
    }

    private var recordDetail: String {
        switch AutoRecordMode(rawValue: autoRecord) ?? .off {
        case .off: return "A notification offers to record each call."
        case .all: return "Every call is recorded unless its source is ignored."
        case .selected: return "Only sources set to Record automatically below."
        }
    }

    var body: some View {
        SettingsGroup("Detection", footer: "Kaiku sees which apps use a microphone, without opening one itself.") {
            SwitchRow("Notice when a call starts", isOn: $detect)
            if detect {
                SettingsRow(Text("Record automatically"), subtitle: Text(recordDetail)) {
                    SegmentedPill([(value: AutoRecordMode.off.rawValue, title: "Off"),
                                   (value: AutoRecordMode.all.rawValue, title: "All calls"),
                                   (value: AutoRecordMode.selected.rawValue, title: "Chosen sources")],
                                  selection: $autoRecord)
                        .fixedSize()
                }
                .settingsAnchor("recordAutomatically")
                SettingsRow(Text("When a call ends"), subtitle: Text(modeDetail)) {
                    Picker("When a call ends", selection: $callEnd) {
                        ForEach(CallEndMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if behavior == .stopAfterDelay {
                    SettingsRow("Stop after") {
                        Picker("Stop after", selection: $autoStop) {
                            Text("Never").tag(0)
                            Text("30 seconds").tag(30)
                            Text("1 minute").tag(60)
                            Text("2 minutes").tag(120)
                            Text("5 minutes").tag(300)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if fallsBack {
                    GroupRow {
                        HStack(spacing: PUI.Space.m) {
                            StatusDot(kind: .warning, text: fallbackNote)
                            Spacer(minLength: PUI.Space.m)
                            Button("Open Notifications") { WindowManager.shared.showSettings(.notifications, anchor: "calls") }
                                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        }
                    }
                }
            }
        }
        .settingsAnchor("detection")
        .onChange(of: detect) { _, _ in MeetingMonitor.shared.apply() }
        .onAppear { permissions.refreshNotifications() }
    }
}

// MARK: - Calendar

private struct CalendarSection: View {
    @AppStorage(Keys.calendarEnabled) private var enabled = true
    @ObservedObject private var permissions = Permissions.shared
    @State private var chosen: Set<String> = []
    @State private var calendars: [(id: String, title: String, account: String)] = []
    @State private var expanded = false

    var body: some View {
        SettingsGroup("Calendar", footer: "Uses the event happening when you start, and suggests its attendees as speaker names. Google and Outlook calendars are added in System Settings > Internet Accounts.") {
            SwitchRow("Name calls after calendar events", isOn: $enabled)
            if enabled {
                if permissions.calendar == .granted {
                    GroupRow {
                        DisclosureGroup("Calendars: " + (chosen.isEmpty ? "All (\(calendars.count))" : "\(chosen.count) of \(calendars.count)"), isExpanded: $expanded) {
                            VStack(alignment: .leading, spacing: PUI.Space.s) {
                                ForEach(calendars, id: \.id) { cal in
                                    Toggle(isOn: Binding(
                                        get: { chosen.isEmpty || chosen.contains(cal.id) },
                                        set: { on in
                                            var set = chosen.isEmpty ? Set(calendars.map(\.id)) : chosen
                                            if on { set.insert(cal.id) } else { set.remove(cal.id) }
                                            // Empty means "all": the last calendar can't be unchecked.
                                            guard !set.isEmpty else { return }
                                            chosen = set.count == calendars.count ? [] : set
                                            AppSettings.defaults.set(Array(chosen).sorted(), forKey: Keys.calendarIDs)
                                        })) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(cal.title).font(PUI.Font.body)
                                            Text(cal.account).font(PUI.Font.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.top, PUI.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(PUI.Font.body)
                    }
                } else {
                    SettingsRow(Text(permissions.calendar == .denied ? "Calendar access denied" : "Needs calendar access")) {
                        Button(permissions.calendar == .notAsked ? "Allow…" : "Open Settings…") { permissions.requestCalendar() }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
        }
        .settingsAnchor("calendar")
        .onAppear(perform: load)
        .onChange(of: permissions.calendar) { _, _ in load() }
    }

    private func load() {
        chosen = Set(AppSettings.calendarIDs)
        calendars = CalendarService.shared.calendars().map { ($0.calendarIdentifier, $0.title, $0.source.title) }
    }
}

// MARK: - Add website

/// Name and title words of a website to add.
private struct AddWebsiteSheet: View {
    let existing: [String]
    let add: (CustomWebsite) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var words = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicate: Bool { existing.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Website").font(.headline)
            Text("Kaiku recognizes a web call by the title of the browser window, not its address.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name, prompt: Text("Client Portal"))
                TextField("Title contains", text: $words, prompt: Text(trimmed.isEmpty ? "Optional, the name by default" : trimmed))
            }
            .formStyle(.columns)
            Text("Separate alternatives with commas. Whole words only: “Meet” doesn't match “Meeting”.")
                .font(.caption).foregroundStyle(.secondary)
            if duplicate {
                Text("\(trimmed) is already a source.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    add(CustomWebsite(name: trimmed, keywords: CustomWebsite.parseKeywords(words)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || duplicate)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The app icon when the source's app is installed, else a symbol.
private struct SourceIcon: View {
    let source: String
    let custom: [CustomApp]

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: isWeb ? "globe" : "app.dashed")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var isWeb: Bool {
        CallSource.known.first { $0.name == source }?.bundlePrefixes.isEmpty ?? !custom.contains { $0.name == source }
    }

    private var icon: NSImage? {
        let ids = custom.filter { $0.name == source }.map(\.bundleID)
            + (CallSource.known.first { $0.name == source }?.bundlePrefixes ?? []) + (Self.mainApps[source] ?? [])
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }

    /// Main app bundle ids where the detection prefix isn't one.
    private static let mainApps: [String: [String]] = [
        "Zoom": ["us.zoom.xos"],
        "Microsoft Teams": ["com.microsoft.teams2", "com.microsoft.teams"],
        "Webex": ["Cisco-Systems.Spark", "com.webex.meetingmanager"],
        "Discord": ["com.hnc.Discord"],
    ]
}
