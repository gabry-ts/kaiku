import Foundation
import KaikuCore

/// Results of the chunks of one track already transcribed, saved next to the track's
/// partial result: when a later chunk fails, trying again doesn't pay for them twice.
/// Set for the duration of a track with `ChunkCache.$current.withValue`.
final class ChunkCache: @unchecked Sendable {
    @TaskLocal static var current: ChunkCache?

    private struct Entry: Codable {
        var segments: [Segment]
        var detectedLanguage: String?
    }

    private struct Stored: Codable {
        var key: String
        var chunks: [String: Entry]
    }

    let url: URL
    private let key: String
    private let lock = NSLock()
    private var chunks: [String: Entry]

    /// - Parameter key: everything that must match for a saved chunk to be reused.
    init(url: URL, key: TrackCache.Key) {
        self.url = url
        self.key = (try? JSONEncoder().encode(key)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        chunks = stored?.key == self.key ? stored?.chunks ?? [:] : [:]
    }

    private static func id(_ index: Int, offset: Double) -> String { "\(index)@\(Int((offset * 1000).rounded()))" }

    func result(index: Int, offset: Double) -> TranscriptionResult? {
        lock.lock()
        defer { lock.unlock() }
        return chunks[Self.id(index, offset: offset)].map { TranscriptionResult(segments: $0.segments, detectedLanguage: $0.detectedLanguage) }
    }

    func save(_ result: TranscriptionResult, index: Int, offset: Double) {
        lock.lock()
        chunks[Self.id(index, offset: offset)] = Entry(segments: result.segments, detectedLanguage: result.detectedLanguage)
        let stored = Stored(key: key, chunks: chunks)
        lock.unlock()
        try? JSONEncoder().encode(stored).write(to: url, options: .atomic)
    }
}
