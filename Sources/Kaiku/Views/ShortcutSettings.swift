import AppKit
import PartitiUI
import SwiftUI
import KaikuCore

// MARK: - Menu Bar & Shortcuts

/// Settings > Menu Bar & Shortcuts: what the menu bar panel shows, and keys that work from any app.
struct MenuBarSettings: View {
    var body: some View {
        KaikuPane(pane: .menuBar, subtitle: "What the menu bar panel shows, and keys that work from any app.") {
            PanelSettings()
            ShortcutSettings()
        }
    }
}

// MARK: - Shortcuts

/// The global shortcuts, and the keys the panel answers to.
struct ShortcutSettings: View {
    @State private var combos = Shortcuts.assignments
    @State private var recording: ShortcutAction?
    @State private var warnings: [ShortcutAction: String] = [:]
    @State private var monitor: Any?
    @State private var showPanelKeys = false
    @ObservedObject private var nav = AppNavigation.shared

    var body: some View {
        Group {
            SettingsGroup("Global Shortcuts", footer: "Click a shortcut and type a new one. Esc cancels, Delete clears.") {
                ForEach(ShortcutAction.allCases) { action in
                    row(action)
                }
                GroupRow {
                    HStack {
                        Spacer()
                        Button("Restore Defaults", action: restoreDefaults)
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                            .disabled(ShortcutAction.allCases.allSatisfy { combos[$0] == $0.defaultCombo })
                    }
                }
            }

            .settingsAnchor("shortcuts")

            SettingsGroup {
                GroupRow {
                    DisclosureGroup(isExpanded: $showPanelKeys) {
                        VStack(spacing: 0) {
                            keyLine("Start Recording", "⌘R")
                            keyLine("Pause or resume", "⌘P")
                            keyLine("Add bookmark", "⌘B")
                            keyLine("Stop recording", "⌘S")
                            keyLine("Open Kaiku", "⌘L")
                            keyLine("Settings", "⌘,")
                            keyLine("Mute or unmute all microphones", "Option-click the menu bar icon")
                        }
                        .padding(.top, PUI.Space.s)
                    } label: {
                        Text("Keys in the panel").font(PUI.Font.body)
                    }
                }
            }
            .settingsAnchor("panelKeys")
        }
        .onAppear { if nav.wants(["panelKeys"], in: .menuBar) { showPanelKeys = true } }
        .onChange(of: nav.request) { _, _ in if nav.wants(["panelKeys"], in: .menuBar) { showPanelKeys = true } }
        .onDisappear { stopRecording() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        GroupRow {
            VStack(alignment: .leading, spacing: PUI.Space.s) {
                HStack(spacing: PUI.Space.s) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title).font(PUI.Font.body)
                        if action == .bookmark {
                            Text("Label it later in the panel or the call.").font(PUI.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: PUI.Space.l)
                    Button {
                        recording == action ? stopRecording() : startRecording(action)
                    } label: {
                        Text(label(for: action))
                            .monospacedDigit()
                            .foregroundStyle(recording == action ? AnyShapeStyle(AppAccent.kaiku.color)
                                             : combos[action] == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    .accessibilityLabel("\(action.title) shortcut")
                    .accessibilityValue(combos[action]?.display ?? "None")
                    .help("Click, then type the new shortcut")
                    Button {
                        reset(action)
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
                if let warning = warnings[action] {
                    StatusDot(kind: .warning, text: warning)
                }
            }
        }
    }

    private func keyLine(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title).font(PUI.Font.callout).foregroundStyle(.secondary)
            Spacer()
            Text(keys).font(PUI.Font.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func label(for action: ShortcutAction) -> String {
        if recording == action { return "Type shortcut…" }
        return combos[action]?.display ?? "None"
    }

    // MARK: Recording

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        warnings[action] = nil
        recording = action
        // Our own global shortcuts would fire instead of being recorded.
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
        let modifiers = Self.modifiers(event.modifierFlags)
        switch (Int(event.keyCode), modifiers.isEmpty) {
        case (53, true): // Esc
            stopRecording()
            return
        case (51, true), (117, true): // Delete, Forward Delete
            stopRecording()
            save(nil, for: action)
            return
        default:
            break
        }
        let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        switch ShortcutRules.validate(combo, for: action, in: combos) {
        case .needsModifier:
            warnings[action] = ShortcutRules.Problem.needsModifier.message
        case .usedBy(let other):
            warnings[action] = ShortcutRules.Problem.usedBy(other).message
            stopRecording()
        case nil:
            stopRecording()
            save(combo, for: action)
        }
    }

    private func save(_ combo: KeyCombo?, for action: ShortcutAction) {
        commit(action) { Shortcuts.set(combo, for: action) }
    }

    private func reset(_ action: ShortcutAction) {
        stopRecording()
        if let combo = action.defaultCombo,
           let other = ShortcutRules.conflict(combo, for: action, in: combos) {
            warnings[action] = ShortcutRules.Problem.usedBy(other).message
            return
        }
        commit(action) { Shortcuts.reset(action) }
    }

    /// Applies a change and registers it; puts the previous shortcut back if macOS
    /// refuses the new one.
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

    private func restoreDefaults() {
        stopRecording()
        ShortcutAction.allCases.forEach(Shortcuts.reset)
        HotKeyManager.apply()
        warnings = [:]
        for action in HotKeyManager.failed { warnings[action] = "This shortcut is in use by another app." }
        combos = Shortcuts.assignments
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }
}
