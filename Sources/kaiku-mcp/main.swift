import Foundation
import KaikuCore

// Kaiku's MCP server for local agents (Claude Code, Codex, Claude Desktop), over stdio:
// one JSON-RPC message per line on stdin and stdout. It reads the recordings folder
// directly, so it works while the app is closed. Logs go to stderr only.

func debugLog(_ message: String) {
    FileHandle.standardError.write(Data("kaiku-mcp: \(message)\n".utf8))
}

struct OpenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The app's saved preferences, read from its persistent domain so that `-key value`
/// command-line arguments can't override them (the edit switch in particular).
func savedPreference(_ key: String) -> Any? {
    UserDefaults.standard.persistentDomain(forName: KaikuAgents.bundleID)?[key]
}

let base = KaikuAgents.baseFolder(savedPath: savedPreference(KaikuAgents.baseFolderKey) as? String)
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

if CommandLine.arguments.contains("--version") {
    print("kaiku-mcp \(version)")
    exit(0)
}

let tools = KaikuToolSet(
    library: CallLibrary(base: base),
    allowEdits: { savedPreference(KaikuAgents.allowEditsKey) as? Bool ?? false },
    openInApp: { request in
        // In the background, launching the app when it isn't running.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", request.url.absoluteString]
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenError(message: "open exited with status \(process.terminationStatus); is Kaiku installed?")
        }
        debugLog("asked the app: \(request.url.absoluteString)")
    },
    changed: {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(KaikuAgents.libraryChangedNotification), object: nil, userInfo: nil, deliverImmediately: true)
    })

let server = MCPServer(name: KaikuAgents.serverName, version: version, instructions: KaikuToolSet.instructions, toolSet: tools)
debugLog("serving \(base.path) (version \(version))")

while let line = readLine(strippingNewline: true) {
    guard let reply = server.handle(line: line) else { continue }
    FileHandle.standardOutput.write(Data((reply + "\n").utf8))
}
