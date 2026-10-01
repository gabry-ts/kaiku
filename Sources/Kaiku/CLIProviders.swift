import Foundation
import KaikuCore

/// Finds and runs the command-line tools used as summary providers.
enum CLIProviders {
    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private static var nodeVersions: [String] {
        let dir = "\(home)/.nvm/versions/node"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// The path set in Settings, when there is one.
    static func customPath(_ tool: CLITool) -> String? {
        let raw = AppSettings.defaults.string(forKey: Keys.cliPath(tool))?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? nil : (raw as NSString).expandingTildeInPath
    }

    /// The tool from Settings, the last detection or the usual install folders. Cheap
    /// enough for views; the login shell is only asked by `detect`.
    static func locate(_ tool: CLITool) -> String? {
        if let custom = customPath(tool) { return isExecutable(custom) ? custom : nil }
        if let cached = AppSettings.defaults.string(forKey: Keys.cliDetected(tool)), isExecutable(cached) { return cached }
        guard let path = tool.candidatePaths(home: home, nodeVersions: nodeVersions).first(where: isExecutable) else {
            return nil
        }
        remember(path, for: tool)
        return path
    }

    /// Like `locate`, then asks the user's login shell, which knows their own PATH.
    static func detect(_ tool: CLITool) async -> String? {
        if let path = locate(tool) { return path }
        guard let output = try? await Shell.run("/bin/zsh", tool.loginShellArguments, timeout: 10),
              let path = CLITool.path(fromShellOutput: output), isExecutable(path) else { return nil }
        remember(path, for: tool)
        return path
    }

    /// Kept across launches, so a tool only the login shell knows is found from the Finder too.
    private static func remember(_ path: String, for tool: CLITool) {
        AppSettings.defaults.set(path, forKey: Keys.cliDetected(tool))
    }

    /// Runs the tool once in an empty temporary folder, prompt on stdin, and returns its answer.
    static func complete(_ tool: CLITool, name: String, model: String, prompt: String,
                         timeout: TimeInterval) async throws -> String {
        guard let binary = await detect(tool) else {
            throw ProviderError(message: "\(name) CLI not found. Install it or set its path in Settings.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaiku-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lastMessage = dir.appendingPathComponent("last-message.txt")

        // Apps opened from the Finder get a minimal PATH; tools may start helpers by name.
        var env = ProcessInfo.processInfo.environment
        let dirs = [(binary as NSString).deletingLastPathComponent]
            + CLITool.searchDirs(home: home, nodeVersions: nodeVersions)
            + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
        env["PATH"] = dirs.joined(separator: ":")

        let out: String
        do {
            out = try await Shell.run(binary, tool.arguments(model: model, workDir: dir.path, outputFile: lastMessage.path),
                                      input: Data(prompt.utf8), workDir: dir, environment: env, timeout: timeout)
        } catch let error as ProcessError {
            throw ProviderError(message: CLITool.stripANSI(error.message))
        }
        return try CLITool.parseOutput(stdout: out, lastMessage: try? String(contentsOf: lastMessage, encoding: .utf8))
    }
}
