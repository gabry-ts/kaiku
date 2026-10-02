import Foundation
import KaikuCore

/// The agents Kaiku's MCP server can be added to from Settings.
enum AgentClient: String, CaseIterable, Identifiable {
    case claudeCode, codex, claudeDesktop
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .claudeDesktop: return "Claude Desktop"
        }
    }

    /// What adding it changes.
    var detail: String {
        switch self {
        case .claudeCode: return "Runs claude mcp add, for all your projects."
        case .codex: return "Adds kaiku to ~/.codex/config.toml."
        case .claudeDesktop: return "Adds kaiku to claude_desktop_config.json."
        }
    }
}

/// Adds kaiku-mcp to the agents' configuration.
enum AgentInstaller {
    /// kaiku-mcp inside the app bundle; nil when running from `swift run`.
    static var serverPath: String? {
        Bundle.main.path(forAuxiliaryExecutable: KaikuAgents.executableName)
    }

    /// Why the server path can't be given to agents yet: it would break once the app moves.
    static var locationProblem: String? {
        guard let path = serverPath else { return nil }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "Kaiku is running from a temporary or disk image location. Move it to /Applications and reopen it before adding agents."
        }
        return nil
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    static var claudeDesktopConfig: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Adds the server and says what happened, or throws with what went wrong.
    static func install(_ client: AgentClient, path: String) async throws -> String {
        switch client {
        case .claudeCode:
            do {
                try await CLIProviders.run(.claude, name: client.displayName, AgentConfig.claudeAddArguments(path: path))
            } catch let error as ProviderError where error.message.contains("already exists") {
                // Added before, maybe from another copy of the app: point it here.
                try await CLIProviders.run(.claude, name: client.displayName, AgentConfig.claudeRemoveArguments())
                try await CLIProviders.run(.claude, name: client.displayName, AgentConfig.claudeAddArguments(path: path))
            }
            Log.app.info("Added kaiku-mcp to Claude Code")
            return "Added. Start a new Claude Code session to use it."
        case .codex:
            let url = codexConfig.resolvingSymlinksInPath()
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let result = try AgentConfig.codex(existing, path: path)
            guard result.change != .unchanged else { return "Already added." }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try result.text.write(to: url, atomically: true, encoding: .utf8)
            Log.app.info("Added kaiku-mcp to \(url.path, privacy: .public)")
            return (result.change == .added ? "Added" : "Updated") + ". Start a new Codex session to use it."
        case .claudeDesktop:
            let url = claudeDesktopConfig.resolvingSymlinksInPath()
            let result = try AgentConfig.claudeDesktop(try? Data(contentsOf: url), path: path)
            guard result.change != .unchanged else { return "Already added." }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try result.data.write(to: url, options: .atomic)
            Log.app.info("Added kaiku-mcp to \(url.path, privacy: .public)")
            return (result.change == .added ? "Added" : "Updated") + ". Quit and reopen Claude Desktop to use it."
        }
    }
}
