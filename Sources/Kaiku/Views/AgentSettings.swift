import AppKit
import KaikuCore
import PartitiUI
import SwiftUI

/// Settings > Agents (MCP): lets Claude Code, Codex and Claude Desktop use the calls
/// through kaiku-mcp, the MCP server bundled with the app.
struct AgentSettings: View {
    @AppStorage(Keys.agentsAllowEdits) private var allowEdits = false
    @State private var results: [AgentClient: (ok: Bool, message: String)] = [:]
    @State private var installing: AgentClient?
    @State private var copied: String?

    private let path = AgentInstaller.serverPath

    var body: some View {
        KaikuPane(pane: .agents, subtitle: "Let Claude Code, Codex and Claude Desktop find, read and search your calls.") {
            SettingsGroup("MCP Server", footer: "Agents start the server themselves when they need it, even while Kaiku is closed. It reads the calls in your recordings folder on this Mac and sends nothing anywhere; the agent decides what to do with what it reads.") {
                if let path {
                    SettingsRow(Text("Server"), subtitle: Text(path)) {
                        copyButton("Copy Path", text: path)
                    }
                    .help(path)
                } else {
                    GroupRow {
                        StatusDot(kind: .warning, text: "kaiku-mcp isn't in this build. Build the app with scripts/build-app.sh to add agents from here.")
                    }
                }
            }

            if let path {
                SettingsGroup("Add to an Agent", footer: "Adds a server named kaiku to the agent's own settings, keeping everything else in them.") {
                    clientRow(.claudeCode, path: path)
                    clientRow(.codex, path: path)
                    clientRow(.claudeDesktop, path: path)
                    if let problem = AgentInstaller.locationProblem {
                        GroupRow { StatusDot(kind: .warning, text: problem) }
                    }
                }

                SettingsGroup("Manual Setup", footer: "For other agents, run the server path as a stdio MCP server, with no arguments.") {
                    GroupRow {
                        HStack(alignment: .firstTextBaseline, spacing: PUI.Space.s) {
                            Text(AgentConfig.claudeCommandLine(path: path))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            copyButton("Copy", text: AgentConfig.claudeCommandLine(path: path))
                        }
                    }
                }
            }

            SettingsGroup("Permissions", footer: "Agents can always list, read and search your calls. With editing allowed they can also rename calls, change tags and speaker names (which rewrites meta.json and transcript.md), and ask Kaiku to transcribe or summarize a call again with the providers chosen here.") {
                SwitchRow("Allow agents to edit calls", isOn: $allowEdits)
            }
        }
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
