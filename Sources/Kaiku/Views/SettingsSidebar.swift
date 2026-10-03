import KaikuCore
import PartitiUI
import SwiftUI

/// The sidebar of the main window while it shows Settings: the way back to the calls, the
/// search field, and the panes in their sections. ↑ and ↓ move between panes. While searching,
/// the results replace the panes and the first one's pane shows beside them.
struct SettingsSidebarView: View {
    @ObservedObject private var nav = AppNavigation.shared
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var hits: [SettingsSearchHit] { SettingsSearch.search(query, in: SettingsIndex.all) }

    var body: some View {
        Group {
            if searching {
                SettingsSearchResults(query: query, hits: hits, selected: $selected, open: open)
            } else {
                paneList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if searching {
                Text("↑↓ to move · Return to open · Esc to clear")
                    .font(PUI.Font.caption).foregroundStyle(.tertiary)
                    .padding(PUI.Space.m)
            }
        }
        .onChange(of: query) { _, _ in
            selected = 0
            if let first = hits.first, let target = SettingsIndex.target(of: first.entry), target.pane != nav.pane {
                nav.open(target.pane)
            }
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
    }

    private func open(_ hit: SettingsSearchHit) {
        guard let target = SettingsIndex.target(of: hit.entry) else { return }
        nav.open(target.pane, anchor: target.anchor)
        AccessibilityNotification.Announcement(hit.entry.title).post()
    }

    private var paneList: some View {
        List(selection: Binding(get: { nav.pane }, set: { if let p = $0 { nav.open(p) } })) {
            ForEach(SettingsPane.Section.allCases, id: \.self) { section in
                Section {
                    ForEach(SettingsPane.allCases.filter { $0.section == section }) { pane in
                        SettingsPaneRow(pane: pane).tag(pane)
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .onExitCommand { nav.closeSettings() }
    }

    private var header: some View {
        let ink = Ink(scheme)
        return VStack(alignment: .leading, spacing: PUI.Space.m) {
            HStack {
                Button { nav.closeSettings() } label: {
                    HStack(spacing: PUI.Space.xs) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppAccent.kaiku.legible(scheme))
                        Text("Settings").font(.system(size: 17, weight: .bold)).foregroundStyle(ink.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to your calls")
                .accessibilityLabel("Back to your calls")
                Spacer()
                Text("⌘[").font(PUI.Font.caption).foregroundStyle(ink.tertiary)
            }
            SettingsSearchField(text: $query, focused: $searchFocused)
                .onSubmit { if hits.indices.contains(selected) { open(hits[selected]) } }
                .onKeyPress(.downArrow) {
                    guard searching else { return .ignored }
                    selected = min(selected + 1, max(hits.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard searching else { return .ignored }
                    selected = max(selected - 1, 0)
                    return .handled
                }
                .onExitCommand { if query.isEmpty { nav.closeSettings() } else { query = "" } }
        }
        .padding(.horizontal, PUI.Space.l)
        .padding(.top, PUI.Space.xs)
        .padding(.bottom, PUI.Space.s)
    }
}

/// Search results, by pane, best first in each; the selected one moves with ↑ and ↓.
private struct SettingsSearchResults: View {
    let query: String
    let hits: [SettingsSearchHit]
    @Binding var selected: Int
    let open: (SettingsSearchHit) -> Void
    @Environment(\.colorScheme) private var scheme

    /// Panes in the order of their best result.
    private var panes: [(pane: SettingsPane, hits: [(index: Int, hit: SettingsSearchHit)])] {
        var order: [SettingsPane] = []
        var byPane: [SettingsPane: [(Int, SettingsSearchHit)]] = [:]
        for (i, hit) in hits.enumerated() {
            guard let pane = SettingsIndex.target(of: hit.entry)?.pane else { continue }
            if byPane[pane] == nil { order.append(pane) }
            byPane[pane, default: []].append((i, hit))
        }
        return order.map { ($0, byPane[$0] ?? []) }
    }

    var body: some View {
        let ink = Ink(scheme)
        ScrollViewReader { proxy in
            ScrollView {
                if hits.isEmpty {
                    VStack(alignment: .leading, spacing: PUI.Space.xs) {
                        Text("No settings match \u{201C}\(query)\u{201D}").font(PUI.Font.body).foregroundStyle(ink.primary)
                        Text("Try \u{201C}key\u{201D}, \u{201C}microphone\u{201D} or \u{201C}summary\u{201D}.")
                            .font(PUI.Font.callout).foregroundStyle(ink.secondary)
                    }
                    .padding(PUI.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LazyVStack(alignment: .leading, spacing: PUI.Space.xxs) {
                    ForEach(panes, id: \.pane) { group in
                        HStack(spacing: PUI.Space.s) {
                            IconTile(group.pane.symbol, color: group.pane.tint, size: 16)
                            Text(group.pane.title).font(PUI.Font.label).foregroundStyle(ink.tertiary)
                        }
                        .padding(.horizontal, PUI.Space.m)
                        .padding(.top, PUI.Space.m)
                        ForEach(group.hits, id: \.index) { item in
                            row(item.hit, on: item.index == selected, ink)
                                .id(item.index)
                        }
                    }
                }
                .padding(.horizontal, PUI.Space.s)
            }
            .onChange(of: selected) { _, i in proxy.scrollTo(i) }
        }
    }

    private func row(_ hit: SettingsSearchHit, on: Bool, _ ink: Ink) -> some View {
        Button { open(hit) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(hit.entry.title)).font(PUI.Font.body).foregroundStyle(ink.primary)
                Group {
                    if let synonym = hit.synonym {
                        Text("\(hit.entry.pane) › \(hit.entry.group) · matches \u{201C}\(synonym)\u{201D}")
                    } else {
                        Text("\(hit.entry.pane) › \(hit.entry.group)")
                    }
                }
                .font(PUI.Font.caption).foregroundStyle(ink.secondary)
                .lineLimit(2)
            }
            .padding(.horizontal, PUI.Space.m)
            .padding(.vertical, PUI.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PUI.Radius.row, style: .continuous)
                .fill(on ? AppAccent.kaiku.color.opacity(scheme == .dark ? 0.28 : 0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func highlighted(_ title: String) -> AttributedString {
        var text = AttributedString(title)
        for range in SettingsSearch.highlights(in: title, query: query) {
            let lower = title.distance(from: title.startIndex, to: range.lowerBound)
            let length = title.distance(from: range.lowerBound, to: range.upperBound)
            let start = text.index(text.startIndex, offsetByCharacters: lower)
            let end = text.index(start, offsetByCharacters: length)
            text[start..<end].backgroundColor = Color.yellow.opacity(0.45)
        }
        return text
    }
}

/// The search field at the top of the settings sidebar. ⌘F puts the cursor in it.
struct SettingsSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        HStack(spacing: PUI.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(ink.secondary)
            TextField("Search Settings", text: $text, prompt: Text("Search"))
                .textFieldStyle(.plain)
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(ink.tertiary)
                    .accessibilityLabel("Clear search")
            } else {
                Text("⌘F").font(PUI.Font.caption).foregroundStyle(ink.tertiary)
            }
        }
        .font(PUI.Font.body)
        .padding(.horizontal, PUI.Space.m)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ink.fill))
        .background {
            Button("Search Settings") { focused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }
}

/// A pane in the settings sidebar: its tile and name.
struct SettingsPaneRow: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: PUI.Space.m) {
            IconTile(pane.symbol, color: pane.tint)
            Text(pane.title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

/// The selected settings pane, beside the sidebar.
struct SettingsDetailView: View {
    @ObservedObject private var nav = AppNavigation.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch nav.pane {
            case .general: GeneralSettings()
            case .menuBar: MenuBarSettings()
            case .recording: RecordingSettings()
            case .callDetection: CallDetectionSettings()
            case .transcription: TranscriptionSettings()
            case .ai: AISettings()
            case .accounts: AccountsSettings()
            case .integrations: IntegrationsSettings()
            case .notifications: NotificationSettings()
            case .permissions: PermissionsSettings()
            case .about: AboutSettings()
            }
        }
        .id(nav.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(scheme == .dark ? Color(white: 0.135) : Color(white: 0.955))
    }
}

/// An entry of the main window's sidebar outside the call list: Calls, Chat, Settings.
struct MainSidebarButton: View {
    let title: String
    let symbol: String
    var selected = false
    /// A dot after the title, for something that needs attention.
    var dot: Color?
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        Button(action: action) {
            HStack(spacing: PUI.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? AppAccent.kaiku.legible(scheme) : ink.secondary)
                    .frame(width: 20)
                Text(title).font(PUI.Font.body).foregroundStyle(ink.primary)
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                        .accessibilityLabel("Needs attention")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PUI.Space.s)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: PUI.Radius.row, style: .continuous)
                .fill(selected ? AppAccent.kaiku.color.opacity(scheme == .dark ? 0.28 : 0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
