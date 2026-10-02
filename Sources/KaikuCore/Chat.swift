import Foundation

/// A call in a chat's context. `ref` is the short id the model cites it by.
public struct ChatCall: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var ref: String
    /// The call folder.
    public var path: String
    public var title: String
    public var date: Date
    public var duration: Double

    public var id: String { ref }

    public init(ref: String, path: String, title: String, date: Date, duration: Double) {
        self.ref = ref
        self.path = path
        self.title = title
        self.date = date
        self.duration = duration
    }
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: UUID
    public var role: Role
    public var text: String
    public var date: Date

    public init(id: UUID = UUID(), role: Role, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

/// One conversation about a set of calls, saved as `<id>.json` in the Chats folder.
public struct ChatConversation: Codable, Equatable, Identifiable, Sendable {
    public var version = 1
    public var id: UUID
    /// The first question, shortened; empty until one is asked.
    public var title: String
    public var created: Date
    public var updated: Date
    public var calls: [ChatCall]
    /// Provider and model of the last answer.
    public var provider: String
    public var model: String
    public var messages: [ChatMessage]

    public init(id: UUID = UUID(), title: String = "", created: Date = Date(), calls: [ChatCall] = [],
                provider: String = "", model: String = "", messages: [ChatMessage] = []) {
        self.id = id
        self.title = title
        self.created = created
        self.updated = created
        self.calls = calls
        self.provider = provider
        self.model = model
        self.messages = messages
    }

    public static let titleLength = 60

    /// A title from the first question: its first line, cut on a word.
    public static func title(from question: String) -> String {
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > titleLength else { return line }
        let cut = line.prefix(titleLength)
        let words = cut.split(separator: " ").dropLast()
        return (words.isEmpty ? String(cut) : words.joined(separator: " ")) + "…"
    }
}

/// Reads and writes the chats of a folder, one JSON file each.
public struct ChatStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ chat: ChatConversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(chat).write(to: url(for: chat.id), options: .atomic)
    }

    /// Every chat that can be read, the latest first.
    public func all() -> [ChatConversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? Self.decode($0) }
            .sorted { $0.updated > $1.updated }
    }

    public func delete(_ id: UUID) throws {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    public static func encode(_ chat: ChatConversation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(chat)
    }

    public static func decode(_ data: Data) throws -> ChatConversation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatConversation.self, from: data)
    }
}

/// Splits output that arrives in pieces into lines. Lines are decoded whole, so a
/// character split across two pieces stays intact.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// The lines completed by `data`, without their line breaks.
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Self.text(pending[pending.startIndex..<newline]))
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// The last line when the output didn't end with a line break.
    public mutating func flush() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : Self.text(pending)
    }

    private static func text(_ data: Data) -> String {
        var line = String(decoding: data, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}
