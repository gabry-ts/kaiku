import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KaikuCore

/// Which apps and websites can start a recording: Always, Never or New (ask the first
/// time). Apps can be added from the Finder, and any source removed from the list.
struct SourcesSettings: View {
    @State private var rules = SourceRules()
    @State private var custom: [CustomApp] = []
    @State private var removed: [String] = []
    @State private var sources: [String] = []
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                ForEach(sources, id: \.self) { source in
                    HStack(spacing: 10) {
                        SourceIcon(source: source, custom: custom)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source)
                            Text(kind(of: source)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
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
                        .buttonStyle(.borderless)
                        .help("Remove \(source)")
                        .accessibilityLabel("Remove \(source)")
                    }
                }
                HStack {
                    Button("Add App…", systemImage: "plus") { addApp() }
                    if let message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Always records (or asks to record) as usual. Never ignores the source. New records the first time, then asks whether to always record it. The same service is one source in its app and on the web, like WhatsApp and WhatsApp Web. Web calls are told apart by the browser window title, which needs the Accessibility permission.")
            }

            if !removed.isEmpty {
                Section {
                    ForEach(removed, id: \.self) { source in
                        HStack {
                            Text(source).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { restore(source) }
                        }
                    }
                } header: {
                    Text("Removed")
                } footer: {
                    Text("Removed sources are ignored, like Never.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func kind(of source: String) -> String {
        if custom.contains(where: { $0.name == source }) { return "Added app" }
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
        removed = AppSettings.removedSources
        refresh()
    }

    private func refresh() {
        sources = rules.listed(seen: AppSettings.seenSources, custom: custom, removed: removed)
    }

    private func save() {
        AppSettings.sourceRules = rules
        AppSettings.customApps = custom
        AppSettings.removedSources = removed
        refresh()
    }

    /// Added apps disappear; any other source moves to Removed and is ignored.
    private func remove(_ source: String) {
        message = nil
        if let i = custom.firstIndex(where: { $0.name == source }) {
            custom.remove(at: i)
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

    private var isWeb: Bool { CallSource.known.first { $0.name == source }?.bundlePrefixes.isEmpty ?? !custom.contains { $0.name == source } }

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
