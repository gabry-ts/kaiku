import AppKit
import KaikuCore
import PartitiUI
import SwiftUI

/// Settings > Integrations > Agents (MCP): lets Claude Code, Codex and Claude Desktop use the calls
/// through kaiku-mcp, the MCP server bundled with the app.
struct AgentSettings: View {
    @AppStorage(Keys.agentsAllowEdits) private var allowEdits = false
    @State private var results: [AgentClient: (ok: Bool, message: String)] = [:]
    @State private var installing: AgentClient?
    @State private var copied: String?

    private let path = AgentInstaller.serverPath

    @State private var confirmEdits = false
    @State private var showManual = false
    @ObservedObject private var nav = AppNavigation.shared

    var body: some View {
        SettingsGroup("Agents (MCP)", footer: "Agents read the calls on this Mac. Reading is always allowed; editing only with the switch on.") {
            if let path {
                clientRow(.claudeCode, path: path)
                clientRow(.codex, path: path)
                clientRow(.claudeDesktop, path: path)
                if let problem = AgentInstaller.locationProblem {
                    GroupRow { StatusDot(kind: .warning, text: problem) }
                }
            } else {
                GroupRow { StatusDot(kind: .warning, text: "kaiku-mcp isn't in this build.") }
            }
            SwitchRow("Allow agents to edit calls", isOn: Binding(get: { allowEdits }, set: { on in
                if on { confirmEdits = true } else { allowEdits = false }
            }))
            .settingsAnchor("agentsEdit")
            if let path {
                DisclosureRow(title: "Manual Setup", detail: "For other agents", isOpen: $showManual)
                    .settingsAnchor("manualSetup")
                if showManual {
                    SettingsRow(Text("Server"), subtitle: Text(path)) {
                        copyButton("Copy Path", text: path)
                    }
                    .help(path)
                    snippetRow("Claude Code", AgentConfig.claudeCommandLine(path: path))
                    snippetRow("Codex, in ~/.codex/config.toml", AgentConfig.codexSnippet(path: path))
                    snippetRow("Claude Desktop, in claude_desktop_config.json", AgentConfig.claudeDesktopSnippet(path: path))
                }
            }
        }
        .settingsAnchor("agents")
        .confirmationDialog("Allow agents to edit calls?", isPresented: $confirmEdits) {
            Button("Allow Editing") { allowEdits = true }
        } message: {
            Text("Agents will be able to rename calls, change tags and speakers, and run transcriptions and summaries again.")
        }
        .onAppear { if nav.wants(["manualSetup"], in: .integrations) { showManual = true } }
        .onChange(of: nav.request) { _, _ in if nav.wants(["manualSetup"], in: .integrations) { showManual = true } }

        SettingsGroup("Raycast", footer: "Needs the Kaiku extension from the Raycast Store.") {
            SettingsRow(Text("Raycast"), subtitle: Text("Control recordings and search your calls from Raycast.")) {
                Button("Install in Raycast") {
                    if let url = URL(string: "raycast://extensions/gabry-ts/kaiku") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            }
        }
        .settingsAnchor("raycast")
    }

    @ViewBuilder
    private func clientRow(_ client: AgentClient, path: String) -> some View {
        SettingsRow(Text(client.displayName), subtitle: Text(client.detail)) {
            HStack(spacing: PUI.Space.s) {
                if installing == client { ProgressView().controlSize(.small) }
                Button("Add to \(client.displayName)") { install(client, path: path) }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    .disabled(installing != nil || AgentInstaller.locationProblem != nil)
            }
        }
        if let result = results[client] {
            GroupRow {
                StatusDot(kind: result.ok ? .ok : .error, text: result.message)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    private func snippetRow(_ title: String, _ text: String) -> some View {
        GroupRow {
            VStack(alignment: .leading, spacing: PUI.Space.xs) {
                Text(title).font(.system(size: 11, weight: .medium))
                HStack(alignment: .top, spacing: PUI.Space.s) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    copyButton("Copy", text: text)
                }
            }
        }
    }

    private func copyButton(_ title: String, text: String) -> some View {
        Button(copied == text ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = text
        }
        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
    }

    private func install(_ client: AgentClient, path: String) {
        installing = client
        results[client] = nil
        Task {
            do {
                let message = try await AgentInstaller.install(client, path: path)
                results[client] = (true, message)
            } catch {
                Log.app.error("Adding kaiku-mcp to \(client.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                results[client] = (false, error.localizedDescription)
            }
            installing = nil
        }
    }
}
