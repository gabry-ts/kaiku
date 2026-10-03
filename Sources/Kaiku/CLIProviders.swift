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

    /// Drops the remembered path so the next search starts over.
    static func forget(_ tool: CLITool) {
        AppSettings.defaults.removeObject(forKey: Keys.cliDetected(tool))
    }

    /// Kept across launches, so a tool only the login shell knows is found from the Finder too.
    private static func remember(_ path: String, for tool: CLITool) {
        AppSettings.defaults.set(path, forKey: Keys.cliDetected(tool))
    }

    /// Runs the tool once in an empty temporary folder, prompt on stdin, and returns its answer.
    static func complete(_ tool: CLITool, name: String, model: String, prompt: String,
                         timeout: TimeInterval) async throws -> String {
        guard let binary = await detect(tool) else {
            throw ProviderError(message: "\(name) CLI not found. Install it or set its path in Settings > Accounts.")
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

    /// Runs the tool with `args` (e.g. to change its settings) and returns its output.
    @discardableResult
    static func run(_ tool: CLITool, name: String, _ args: [String], timeout: TimeInterval = 30) async throws -> String {
        guard let binary = await detect(tool) else {
            throw ProviderError(message: "\(name) CLI not found. Install it or set its path in Settings > Accounts.")
        }
        var env = ProcessInfo.processInfo.environment
        let dirs = [(binary as NSString).deletingLastPathComponent]
            + CLITool.searchDirs(home: home, nodeVersions: nodeVersions)
            + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
        env["PATH"] = dirs.joined(separator: ":")
        do {
            return try await Shell.run(binary, args, environment: env, timeout: timeout)
        } catch let error as ProcessError {
            throw ProviderError(message: CLITool.stripANSI(error.message))
        }
    }

    /// Answers a chat question with the tool, which reads the call files itself. `update` gets
    /// the whole answer so far as `.answer` (Claude Code as it is written, OpenCode a part at a
    /// time; Codex only answers at the end) and `.tool` while the tool reads.
    /// - Parameters:
    ///   - workDir: where the tool runs; an empty temporary folder when nil.
    ///   - readableDirs: the call folders the tool may read.
    @MainActor
    static func chat(_ tool: CLITool, name: String, model: String, prompt: String, workDir: URL?, readableDirs: [String],
                     timeout: TimeInterval, update: @escaping @MainActor (ChatStreamEvent) -> Void) async throws -> String {
        guard let binary = await detect(tool) else {
            throw ProviderError(message: "\(name) CLI not found. Install it or set its path in Settings > Accounts.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaiku-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lastMessage = dir.appendingPathComponent("last-message.txt")
        let runDir = workDir ?? dir

        var env = ProcessInfo.processInfo.environment
        let dirs = [(binary as NSString).deletingLastPathComponent]
            + CLITool.searchDirs(home: home, nodeVersions: nodeVersions)
            + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
        env["PATH"] = dirs.joined(separator: ":")
        let args = tool.chatArguments(model: model, workDir: runDir.path, outputFile: lastMessage.path, readableDirs: readableDirs)

        let reply = ChatReply()
        let out = try await StreamingProcess.run(binary, args, input: Data(prompt.utf8), workDir: runDir, scratch: dir,
                                                 environment: env, timeout: timeout) { line in
            switch tool {
            case .claude:
                switch ChatAPI.parseClaudeCode(line) {
                case .answer(let text):
                    reply.answer = text
                    update(.answer(text))
                case .error(let message):
                    reply.error = message
                case .reset:
                    // A new message after using a tool: what came before was its preamble.
                    reply.text = ""
                    update(.answer(""))
                case .text(let text):
                    reply.text += text
                    update(.answer(reply.text))
                case .tool(let name):
                    update(.tool(name))
                case .done, .ignored:
                    break
                }
            case .opencode:
                let clean = CLITool.stripANSI(line)
                if ChatAPI.isOpenCodeToolLine(clean) {
                    update(.tool(""))
                } else {
                    reply.text += (reply.text.isEmpty ? "" : "\n") + clean
                    update(.answer(reply.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            case .codex:
                break
            }
        }
        // Claude Code says why it failed in its last line.
        if let error = reply.error { throw ProviderError(message: error) }
        if out.status != 0 { throw ProviderError(message: out.failure) }
        switch tool {
        case .claude:
            return try CLITool.parseOutput(stdout: reply.answer.flatMap { $0.isEmpty ? nil : $0 } ?? reply.text)
        case .opencode:
            return try CLITool.parseOutput(stdout: reply.text)
        case .codex:
            return try CLITool.parseOutput(stdout: out.stdout, lastMessage: try? String(contentsOf: lastMessage, encoding: .utf8))
        }
    }

    /// What a tool answered so far.
    @MainActor
    private final class ChatReply {
        var text = ""
        var answer: String?
        var error: String?
    }
}

/// Runs a tool and hands over each line of its output as soon as it is printed.
enum StreamingProcess {
    struct Output {
        let stdout: String
        let status: Int32
        /// The end of stderr (or of stdout, where some tools print their errors), for a failed run.
        let failure: String
    }

    /// Runs `executable` with `input` on stdin and waits for it to exit. Stops it when the
    /// task is cancelled or after `timeout` seconds.
    /// - Parameter scratch: a folder for the stdin and stderr files.
    static func run(_ executable: String, _ args: [String], input: Data, workDir: URL, scratch: URL,
                    environment: [String: String], timeout: TimeInterval,
                    line: @escaping @MainActor (String) -> Void) async throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProviderError(message: "Executable not found: \(executable)")
        }
        let inURL = scratch.appendingPathComponent("stdin.txt")
        let errURL = scratch.appendingPathComponent("stderr.txt")
        try input.write(to: inURL)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? errHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = workDir
        process.environment = environment
        process.standardInput = try FileHandle(forReadingFrom: inURL)
        process.standardError = errHandle
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = ExitStatus()
        process.terminationHandler = { exited.finish($0.terminationStatus) }

        try process.run()
        let reader = pipe.fileHandleForReading
        let lines = AsyncStream<String> { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = LineBuffer()
                // Ends when the tool exits and its end of the pipe closes.
                while true {
                    let data = reader.availableData
                    if data.isEmpty { break }
                    for text in buffer.append(data) { continuation.yield(text) }
                }
                if let rest = buffer.flush() { continuation.yield(rest) }
                continuation.finish()
            }
        }

        let timedOut = ExitStatus()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOut.finish(1)
            process.terminate()
        }

        var stdout = ""
        await withTaskCancellationHandler {
            for await text in lines {
                stdout += text + "\n"
                await line(text)
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        let status = await exited.wait()
        try Task.checkCancellation()

        let name = (executable as NSString).lastPathComponent
        if timedOut.isFinished { throw ProviderError(message: "\(name) timed out after \(Int(timeout)) s") }
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        let err = (stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr).suffix(800)
        return Output(stdout: stdout, status: status, failure: CLITool.stripANSI("\(name) failed (\(status)): \(err)"))
    }

    /// A value set once from another thread and awaited once.
    private final class ExitStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var waiter: CheckedContinuation<Int32, Never>?

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return status != nil
        }

        func finish(_ value: Int32) {
            lock.lock()
            guard status == nil else { lock.unlock(); return }
            status = value
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: value)
        }

        func wait() async -> Int32 {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let status {
                    lock.unlock()
                    continuation.resume(returning: status)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }
}
