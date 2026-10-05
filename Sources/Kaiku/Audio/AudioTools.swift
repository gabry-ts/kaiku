import AVFoundation
import Foundation
import KaikuCore

struct ProcessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Shell {
    /// Runs an executable and waits for it. Output goes to temp files to avoid pipe deadlocks.
    /// Returns stdout; throws with stderr tail on non-zero exit. The process is terminated
    /// when the task is cancelled or after `timeout` seconds.
    @discardableResult
    static func run(_ executable: String, _ args: [String], input: Data? = nil, workDir: URL? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval? = nil) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError(message: "Executable not found: \(executable)")
        }
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent(UUID().uuidString + ".out")
        let errURL = tmp.appendingPathComponent(UUID().uuidString + ".err")
        let inURL = tmp.appendingPathComponent(UUID().uuidString + ".in")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
            try? FileManager.default.removeItem(at: inURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = outHandle
        process.standardError = errHandle
        if let input {
            try input.write(to: inURL)
            process.standardInput = try FileHandle(forReadingFrom: inURL)
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        if let workDir { process.currentDirectoryURL = workDir }
        if let environment { process.environment = environment }

        let timedOut = Flag()
        let cancelled = Flag()
        let status: Int32 = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { cont in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do { try process.run() } catch { cont.resume(throwing: error); return }
                // Cancelled between the check above and the launch: onCancel saw no process.
                if cancelled.value { process.terminate() }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        timedOut.value = true
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            cancelled.value = true
            if process.isRunning { process.terminate() }
        }
        try? outHandle.close()
        try? errHandle.close()

        try Task.checkCancellation()
        let name = (executable as NSString).lastPathComponent
        if timedOut.value, let timeout {
            throw ProcessError(message: "\(name) timed out after \(Int(timeout)) s")
        }
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        if status != 0 {
            let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            // Some tools print their errors on stdout.
            let err = (stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out : stderr).suffix(800)
            throw ProcessError(message: "\(name) failed (\(status)): \(err)")
        }
        return out
    }

    private final class Flag: @unchecked Sendable {
        var value = false
    }
}
