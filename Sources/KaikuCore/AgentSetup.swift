import Foundation

/// What the app and its MCP server (kaiku-mcp) share.
public enum KaikuAgents {
    /// The app's bundle id, also the domain of its preferences.
    public static let bundleID = "com.gabrielepartiti.kaiku"
    /// Name of the MCP server in the agents' configs.
    public static let serverName = "kaiku"
    public static let executableName = "kaiku-mcp"
    /// Preferences keys read by the server.
    public static let baseFolderKey = "baseFolder"
    public static let allowEditsKey = "agentsAllowEdits"
    /// Posted by the server after it changes a call, so the open library reloads.
    public static let libraryChangedNotification = "com.gabrielepartiti.kaiku.libraryChanged"

    /// The recordings folder saved in the app's preferences, ~/Documents/Kaiku when unset.
    public static func baseFolder(savedPath: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let path = (savedPath ?? "").trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? home.appendingPathComponent("Documents/Kaiku", isDirectory: true)
            : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}

/// Work only the app can do, asked for by the MCP server with a `kaiku://` URL.
public enum AgentRequest: Equatable, Sendable {
    case transcribe(folder: String)
    case summarize(folder: String)

    public static let scheme = "kaiku"

    public var folder: String {
        switch self {
        case .transcribe(let f), .summarize(let f): return f
        }
    }

    private var action: String {
        switch self {
        case .transcribe: return "transcribe"
        case .summarize: return "summarize"
        }
    }

    /// `kaiku://transcribe?folder=%2FUsers%2F…`
    public var url: URL {
        let allowed = CharacterSet(charactersIn: AgentConfig.asciiAlphanumerics + "-._~")
        let value = folder.addingPercentEncoding(withAllowedCharacters: allowed) ?? folder
        return URL(string: "\(Self.scheme)://\(action)?folder=\(value)")!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let folder = parts.queryItems?.first(where: { $0.name == "folder" })?.value, !folder.isEmpty else { return nil }
        switch url.host?.lowercased() {
        case "transcribe": self = .transcribe(folder: folder)
        case "summarize": self = .summarize(folder: folder)
        default: return nil
        }
    }
}

/// Adds the MCP server to the configuration of Claude Code, Codex and Claude Desktop.
public enum AgentConfig {
    public enum Change: Equatable, Sendable {
        case added, updated, unchanged
    }

    /// `claude mcp add` arguments, for the user's own settings.
    public static func claudeAddArguments(path: String) -> [String] {
        ["mcp", "add", "--scope", "user", KaikuAgents.serverName, "--", path]
    }

    public static func claudeRemoveArguments() -> [String] {
        ["mcp", "remove", "--scope", "user", KaikuAgents.serverName]
    }

    /// The command to paste in a terminal.
    public static func claudeCommandLine(path: String) -> String {
        (["claude"] + claudeAddArguments(path: path)).map(shellQuoted).joined(separator: " ")
    }

    /// Quoted for a POSIX shell when it needs to be.
    public static func shellQuoted(_ s: String) -> String {
        let plain = CharacterSet(charactersIn: asciiAlphanumerics + "-_./=:@%+,")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ plain.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let asciiAlphanumerics = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    // MARK: Codex

    static let codexTable = "mcp_servers.\(KaikuAgents.serverName)"

    /// The `[mcp_servers.kaiku]` table for ~/.codex/config.toml.
    public static func codexSnippet(path: String) -> String {
        "[\(codexTable)]\ncommand = \(tomlString(path))\n"
    }

    /// `config` (the text of ~/.codex/config.toml, empty when missing) with the server
    /// added at the end, or its command changed when the table is already there. Everything
    /// else is kept as is. Throws when kaiku is defined in a form other than its own table
    /// (dotted keys or an inline table), since adding the table would duplicate it.
    public static func codex(_ config: String, path: String) throws -> (text: String, change: Change) {
        var lines = config.components(separatedBy: "\n")
        if definesServerOutsideTable(lines) {
            throw ConfigError(message: "~/.codex/config.toml defines mcp_servers.kaiku with dotted keys or an inline table; change it to a [mcp_servers.kaiku] table or remove it first.")
        }
        guard let header = lines.firstIndex(where: { isCodexHeader($0) }) else {
            var text = config
            if !text.isEmpty {
                if !text.hasSuffix("\n") { text += "\n" }
                if !text.hasSuffix("\n\n") { text += "\n" }
            }
            return (text + codexSnippet(path: path), .added)
        }
        let end = lines[(header + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        let command = "command = \(tomlString(path))"
        if let i = lines[(header + 1)..<end].firstIndex(where: { tomlKey($0) == "command" }) {
            guard tomlValue(lines[i]) != path else { return (config, .unchanged) }
            lines[i] = command
        } else {
            lines.insert(command, at: header + 1)
        }
        return (lines.joined(separator: "\n"), .updated)
    }

    /// True when a line outside the `[mcp_servers.kaiku]` tables sets mcp_servers.kaiku, as
    /// dotted keys (`mcp_servers.kaiku.command = …`) or inline (`kaiku = { … }`).
    private static func definesServerOutsideTable(_ lines: [String]) -> Bool {
        func bare(_ s: Substring) -> String { s.filter { $0 != " " && $0 != "\t" && $0 != "\"" && $0 != "'" } }
        let target = codexTable
        var table = ""
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                table = bare(Substring(t)).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                continue
            }
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            if table == target || table.hasPrefix(target + ".") { continue }
            let key = bare(t[..<eq])
            let full = table.isEmpty ? key : table + "." + key
            if full == target || full.hasPrefix(target + ".") { return true }
            if full == "mcp_servers", bare(t[t.index(after: eq)...]).contains("\(KaikuAgents.serverName)=") { return true }
        }
        return false
    }

    private static func isCodexHeader(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        let name = KaikuAgents.serverName
        return t.hasPrefix("[") && !t.hasPrefix("[[")
            && ["[mcp_servers.\(name)]", "[mcp_servers.\"\(name)\"]", "[ mcp_servers.\(name) ]"].contains(where: { t.hasPrefix($0) })
    }

    /// The key of a `key = value` line.
    private static func tomlKey(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return line[..<eq].trimmingCharacters(in: .whitespaces)
    }

    /// The value of a `key = "value"` line, for comparing; nil when it isn't a plain string.
    private static func tomlValue(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("'"), let close = v.dropFirst().firstIndex(of: "'") {
            return String(v[v.index(after: v.startIndex)..<close])
        }
        guard v.count >= 2, v.hasPrefix("\"") else { return nil }
        var out = ""
        var escaped = false
        for c in v.dropFirst() {
            if escaped {
                out.append(c == "n" ? "\n" : c == "t" ? "\t" : c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                return out
            } else {
                out.append(c)
            }
        }
        return nil
    }

    /// A TOML basic string.
    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Claude Desktop

    public struct ConfigError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// claude_desktop_config.json (nil or empty when missing) with `mcpServers.kaiku` set
    /// to the server. The other keys and servers are kept; the file is pretty-printed.
    public static func claudeDesktop(_ data: Data?, path: String) throws -> (data: Data, change: Change) {
        var root: [String: Any] = [:]
        if let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigError(message: "claude_desktop_config.json isn't a JSON object; fix it or remove it first.")
            }
            root = object
        }
        var servers: [String: Any] = [:]
        if let existing = root["mcpServers"] {
            guard let dict = existing as? [String: Any] else {
                throw ConfigError(message: "mcpServers in claude_desktop_config.json isn't an object.")
            }
            servers = dict
        }
        let current = servers[KaikuAgents.serverName] as? [String: Any]
        let change: Change
        if current == nil {
            change = .added
        } else if current?["command"] as? String == path, (current?["args"] as? [Any])?.isEmpty ?? true {
            change = .unchanged
        } else {
            change = .updated
        }
        var entry = current ?? [:]
        entry["command"] = path
        entry["args"] = [String]()
        servers[KaikuAgents.serverName] = entry
        root["mcpServers"] = servers
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return (out + Data("\n".utf8), change)
    }
}
