import Foundation
import KaikuCore

/// A minimal Chrome DevTools Protocol client for the meeting page: run scripts and type text.
final class CDPClient: @unchecked Sendable {
    private var socket: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Connects to the first page target of the browser listening on `port`, dropping any
    /// previous connection.
    func connect(port: Int) async throws {
        if socket != nil { close() }
        let list = URL(string: "http://127.0.0.1:\(port)/json/list")!
        for _ in 0..<40 {
            if let (data, _) = try? await URLSession.shared.data(from: list),
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let page = targets.first(where: { $0["type"] as? String == "page" }),
               let ws = (page["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) {
                let socket = URLSession.shared.webSocketTask(with: ws)
                socket.maximumMessageSize = 16 * 1024 * 1024
                self.socket = socket
                socket.resume()
                receive()
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw AudioCaptureError("Could not connect to Google Chrome")
    }

    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failAll(AudioCaptureError("Google Chrome closed"))
    }

    /// Sends a command and waits for its result.
    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let socket else { throw AudioCaptureError("Google Chrome is not connected") }
        let id: Int = lock.withLock { nextID += 1; return nextID }
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            socket.send(.string(String(decoding: body, as: UTF8.self))) { [weak self] error in
                if let error { self?.resume(id, with: .failure(error)) }
            }
        }
    }

    /// Runs `script` in the page and returns its JSON value.
    func evaluate(_ script: String) async throws -> Any? {
        let reply = try await send("Runtime.evaluate", ["expression": script, "returnByValue": true, "awaitPromise": true])
        if let exception = reply["exceptionDetails"] as? [String: Any] {
            throw AudioCaptureError("Page script failed: \(exception["text"] as? String ?? "unknown")")
        }
        return (reply["result"] as? [String: Any])?["value"]
    }

    /// Types into the focused field, as a keyboard would.
    func insertText(_ text: String) async throws {
        try await send("Input.insertText", ["text": text])
    }

    func pressEnter() async throws {
        for type in ["keyDown", "keyUp"] {
            try await send("Input.dispatchKeyEvent", ["type": type, "key": "Enter", "code": "Enter",
                                                      "windowsVirtualKeyCode": 13, "text": type == "keyDown" ? "\r" : ""])
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   let id = json["id"] as? Int {
                    if let error = json["error"] as? [String: Any] {
                        self.resume(id, with: .failure(AudioCaptureError("DevTools: \(error["message"] as? String ?? "error")")))
                    } else {
                        self.resume(id, with: .success(json["result"] as? [String: Any] ?? [:]))
                    }
                }
                self.receive()
            case .failure(let error):
                self.failAll(error)
            }
        }
    }

    private func resume(_ id: Int, with result: Result<[String: Any], Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let all = lock.withLock { () -> [CheckedContinuation<[String: Any], Error>] in
            defer { pending = [:] }
            return Array(pending.values)
        }
        all.forEach { $0.resume(throwing: error) }
    }
}
