import Foundation
import KaikuCore

/// Finds and runs the command-line tools used as summary providers.
enum CLIProviders {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: [CLITool: String] = [:]

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
        lock.lock()
        let cached = found[tool]
        lock.unlock()
        if let cached, isExecutable(cached) { return cached }
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

    private static func remember(_ path: String, for tool: CLITool) {
        lock.lock()
        found[tool] = path
        lock.unlock()
    }
}
