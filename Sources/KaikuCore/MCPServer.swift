import Foundation

/// Any JSON value, for messages whose shape depends on the method.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Whole numbers, also when sent as 3.0.
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 1e15: return Int(d)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// `.string`, or `.null` for nil.
    public static func optional(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }

    /// Compact JSON, one line.
    public func compactText() -> String { text(pretty: false) }

    /// Indented JSON with sorted keys, for tool results read by a model.
    public func prettyText() -> String { text(pretty: true) }

    private func text(pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A tool an MCP client can call.
public struct MCPTool: Equatable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    var json: JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
    }
}

/// What a tool call returns: text for the model, flagged when the call failed.
public struct MCPToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func error(_ text: String) -> MCPToolResult { MCPToolResult(text: text, isError: true) }

    var json: JSONValue {
        var o: [String: JSONValue] = ["content": [["type": "text", "text": .string(text)]]]
        if isError { o["isError"] = true }
        return .object(o)
    }
}

/// A JSON-RPC error.
public struct MCPError: Error, Equatable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static let parseErrorCode = -32700
    public static let invalidRequestCode = -32600
    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602

    public static func invalidParams(_ message: String) -> MCPError { MCPError(code: invalidParamsCode, message: message) }
}

/// The tools a server offers. Calls run one at a time, in the order they arrive.
public protocol MCPToolSet {
    func tools() -> [MCPTool]
    /// Throws `MCPError` for unknown tools or bad arguments; failures of the tool itself
    /// are results with `isError`.
    func call(_ name: String, arguments: [String: JSONValue]) throws -> MCPToolResult
}

/// An MCP server over newline-delimited JSON-RPC 2.0 (the stdio transport): one message
/// in, at most one message out.
public struct MCPServer {
    public static let latestProtocolVersion = "2025-06-18"
    public static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", latestProtocolVersion]

    public var name: String
    public var version: String
    /// Told to the client at initialization, for the model.
    public var instructions: String?
    public var toolSet: any MCPToolSet

    public init(name: String, version: String, instructions: String? = nil, toolSet: any MCPToolSet) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.toolSet = toolSet
    }

    /// The reply to one line, nil for notifications, responses and blank lines.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return Self.errorResponse(id: .null, MCPError(code: MCPError.parseErrorCode, message: "Parse error"))
        }
        return handle(message)?.compactText()
    }

    /// The reply to one decoded message.
    public func handle(_ message: JSONValue) -> JSONValue? {
        guard case .object(let o) = message else {
            return Self.error(id: .null, MCPError(code: MCPError.invalidRequestCode, message: "Invalid Request"))
        }
        let id = o["id"]
        guard let method = o["method"]?.stringValue else {
            // A response from the client (we never ask it anything), or junk.
            if o["result"] != nil || o["error"] != nil { return nil }
            return Self.error(id: id ?? .null, MCPError(code: MCPError.invalidRequestCode, message: "Invalid Request"))
        }
        // Notifications (no id) never get a reply, not even an error.
        guard let id else { return nil }
        let params = o["params"] ?? .object([:])
        do {
            let value = try result(method: method, params: params)
            return ["jsonrpc": "2.0", "id": id, "result": value]
        } catch let error as MCPError {
            return Self.error(id: id, error)
        } catch {
            return Self.error(id: id, MCPError(code: -32603, message: error.localizedDescription))
        }
    }

    private func result(method: String, params: JSONValue) throws -> JSONValue {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(asked) ? asked : Self.latestProtocolVersion
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return .object(result)
        case "ping":
            return .object([:])
        case "tools/list":
            return ["tools": .array(toolSet.tools().map(\.json))]
        case "tools/call":
            guard let name = params["name"]?.stringValue else { throw MCPError.invalidParams("Missing tool name") }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let a)?: arguments = a
            default: throw MCPError.invalidParams("arguments must be an object")
            }
            return try toolSet.call(name, arguments: arguments).json
        default:
            throw MCPError(code: MCPError.methodNotFoundCode, message: "Method not found: \(method)")
        }
    }

    private static func error(id: JSONValue, _ error: MCPError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]]
    }

    private static func errorResponse(id: JSONValue, _ error: MCPError) -> String {
        Self.error(id: id, error).compactText()
    }
}

/// Reads tool arguments, throwing `invalidParams` with a message the model can act on.
public struct MCPArguments {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue]) {
        self.values = values
    }

    /// A trimmed string; nil when missing, null or blank.
    public func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        default: throw MCPError.invalidParams("\(key) must be a string")
        }
    }

    public func requiredString(_ key: String) throws -> String {
        guard let s = try string(key) else { throw MCPError.invalidParams("\(key) is required") }
        return s
    }

    /// A string as sent, blank allowed; nil when missing.
    public func rawString(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let s)?: return s
        default: throw MCPError.invalidParams("\(key) must be a string")
        }
    }

    /// A whole number in `range`, `defaultValue` when missing.
    public func int(_ key: String, default defaultValue: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let v = values[key], v != .null else { return defaultValue }
        guard let i = v.intValue ?? v.stringValue.flatMap({ Int($0) }) else {
            throw MCPError.invalidParams("\(key) must be a whole number")
        }
        guard range.contains(i) else {
            throw MCPError.invalidParams("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return i
    }

    /// A list of strings; a single string counts as a list of one.
    public func strings(_ key: String) throws -> [String]? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let s)?: return [s]
        case .array(let a)?:
            return try a.map { v -> String in
                guard let s = v.stringValue else { throw MCPError.invalidParams("\(key) must be a list of strings") }
                return s
            }
        default: throw MCPError.invalidParams("\(key) must be a list of strings")
        }
    }

    /// One of `allowed`, `defaultValue` when missing.
    public func choice(_ key: String, _ allowed: [String], default defaultValue: String) throws -> String {
        guard let s = try string(key)?.lowercased() else { return defaultValue }
        guard allowed.contains(s) else {
            throw MCPError.invalidParams("\(key) must be one of: " + allowed.joined(separator: ", "))
        }
        return s
    }
}
