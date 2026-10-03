import KaikuCore
import PartitiUI
import SwiftUI

/// The sidebar of the main window while it shows Settings: the way back to the calls, the
/// search field, and the panes in their sections. ↑ and ↓ move between panes.
struct SettingsSidebarView: View {
    @ObservedObject private var nav = AppNavigation.shared
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
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
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .onExitCommand { if query.isEmpty { nav.closeSettings() } else { query = "" } }
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
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
        }
        .padding(.horizontal, PUI.Space.l)
        .padding(.top, PUI.Space.xs)
        .padding(.bottom, PUI.Space.s)
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
