import Foundation

/// Command-line tools that answer a prompt with the user's own subscription or setup.
/// The prompt always goes on stdin; each run happens in an empty temporary folder.
public enum CLITool: String, CaseIterable, Sendable {
    case claude, codex, opencode

    public var binaryName: String { rawValue }

    /// Replaces the coding-agent prompt of Claude Code: shorter and plain text only.
    public static let systemPrompt = "You are a concise assistant. Follow the user's instructions exactly and reply with plain text only."

    /// Model names the tool documents; anything else can still be typed.
    public var modelSuggestions: [String] {
        switch self {
        case .claude: return ["fable", "opus", "sonnet", "haiku"]
        case .codex, .opencode: return []
        }
    }

    /// Arguments for one non-interactive answer without tools. An empty model leaves
    /// the tool's own default. `outputFile` is where Codex writes its last message.
    public func arguments(model: String, workDir: String, outputFile: String) -> [String] {
        let model = model.trimmingCharacters(in: .whitespaces)
        switch self {
        case .claude:
            var args = ["-p", "--output-format", "text", "--tools", "", "--no-session-persistence",
                        "--strict-mcp-config", "--setting-sources", "", "--system-prompt", Self.systemPrompt]
            if !model.isEmpty { args += ["--model", model] }
            return args
        case .codex:
            var args = ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-rules", "-s", "read-only",
                        "--color", "never", "-C", workDir, "-o", outputFile]
            if !model.isEmpty { args += ["-m", model] }
            return args + ["-"]
        case .opencode:
            var args = ["run", "--pure", "--dir", workDir]
            if !model.isEmpty { args += ["-m", model] }
            return args
        }
    }

    /// Folders where these tools are usually installed. Apps opened from the Finder
    /// get a minimal PATH, so these are searched directly.
    /// - Parameter nodeVersions: folder names under `~/.nvm/versions/node`, newest first.
    public static func searchDirs(home: String, nodeVersions: [String] = []) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
         "\(home)/.bun/bin", "\(home)/.opencode/bin", "\(home)/.claude/local"]
            + nodeVersions.map { "\(home)/.nvm/versions/node/\($0)/bin" }
    }

    public func candidatePaths(home: String, nodeVersions: [String] = []) -> [String] {
        Self.searchDirs(home: home, nodeVersions: nodeVersions).map { "\($0)/\(binaryName)" }
    }

    /// Arguments for `/bin/zsh` that print where the login shell finds the tool.
    public var loginShellArguments: [String] { ["-lc", "command -v \(binaryName)"] }

    /// The path in the login shell's output, skipping anything its startup files print.
    public static func path(fromShellOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    /// The answer: Codex's last-message file when it has one, else stdout without colors.
    public static func parseOutput(stdout: String, lastMessage: String? = nil) throws -> String {
        if let last = lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty { return last }
        let text = stripANSI(stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.invalid("empty reply") }
        return text
    }

    /// Removes terminal color and cursor codes.
    public static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// `provider/model` lines printed by `opencode models`.
    public static func parseOpenCodeModels(_ output: String) -> [String] {
        stripANSI(output).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") && $0.contains("/") }
    }
}
