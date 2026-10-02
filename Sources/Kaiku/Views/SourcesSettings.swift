import AppKit
import PartitiUI
import SwiftUI
import UniformTypeIdentifiers
import KaikuCore

/// Which apps and websites can start a recording: Always, Never or New (ask the first
/// time). Apps can be added from the Finder, websites by words in their window title,
/// and any source removed from the list.
struct SourcesSettings: View {
    @State private var rules = SourceRules()
    @State private var custom: [CustomApp] = []
    @State private var sites: [CustomWebsite] = []
    @State private var addingWebsite = false
    @State private var removed: [String] = []
    @State private var sources: [String] = []
    @State private var message: String?

    var body: some View {
        KaikuPane(pane: .sources, subtitle: "Which apps and websites can start a recording.") {
            SettingsGroup("Sources", footer: "Always records (or asks to record) as usual. Never ignores the source. New records the first time, then asks whether to always record it. The same service is one source in its app and on the web, like WhatsApp and WhatsApp Web. Web calls are told apart by the browser window title, which needs the Accessibility permission.") {
                ForEach(sources, id: \.self) { source in
                    GroupRow {
                        HStack(spacing: PUI.Space.m + 2) {
                            SourceIcon(source: source, custom: custom)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source).font(PUI.Font.body)
                                Text(kind(of: source)).font(PUI.Font.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: PUI.Space.l)
                            Picker(source, selection: Binding(
                                get: { rules.rule(for: source) },
                                set: { rule in
                                    rules.set(rule, for: source)
                                    save()
                                })) {
                                Text("Always").tag(SourceRule.always)
                                Text("Never").tag(SourceRule.never)
                                Text("New (ask)").tag(SourceRule.new)
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button { remove(source) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(source)")
                            .accessibilityLabel("Remove \(source)")
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
            }

            if !removed.isEmpty {
                SettingsGroup("Removed", footer: "Removed sources are ignored, like Never.") {
                    ForEach(removed, id: \.self) { source in
                        SettingsRow(source) {
                            Button("Restore") { restore(source) }
                                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        // A rule set from a notification ("Never") or a newly seen source while this is open.
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.sourcesChanged)) { _ in load() }
        .sheet(isPresented: $addingWebsite) {
            AddWebsiteSheet(existing: sources + removed) { site in addWebsite(site) }
                .puiAccent(.kaiku)
        }
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
