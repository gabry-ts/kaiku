import Foundation

/// Cuts the growing audio of one track into chunks for an engine that can only transcribe
/// finished pieces. Every chunk starts a little before the end of the previous one, so a
/// word cut at the edge is heard whole the second time. Chunks wait here until the engine
/// takes them; when it falls behind, the oldest is dropped instead of adding delay.
public struct ChunkPlanner: Equatable, Sendable {
    /// A range of samples, counted from the first one the track was given.
    public struct Chunk: Equatable, Sendable {
        /// First sample to transcribe, the overlap included.
        public let start: Int
        /// First sample no earlier chunk covered.
        public let fresh: Int
        /// One past the last sample.
        public let end: Int
    }

    /// New samples per chunk.
    public let step: Int
    /// Samples repeated from the previous chunk.
    public let overlap: Int
    public let maxPending: Int

    /// The chunks ready to transcribe, oldest first.
    public private(set) var pending: [Chunk] = []
    /// How many chunks were given up because the engine was behind.
    public private(set) var dropped = 0
    private var total = 0
    private var planned = 0

    public init(sampleRate: Int, seconds: Double = 10, overlap: Double = 2, maxPending: Int = 2) {
        step = max(1, Int(Double(sampleRate) * seconds))
        self.overlap = max(0, Int(Double(sampleRate) * overlap))
        self.maxPending = max(1, maxPending)
    }

    /// Call with the number of samples of every buffer, in order.
    public mutating func add(_ count: Int) {
        total += max(0, count)
        while total - planned >= step { push(end: planned + step) }
    }

    /// Turns what is left at the end of the recording into a last chunk, unless it is
    /// shorter than `minimum` samples.
    public mutating func finish(minimum: Int) {
        if total - planned >= max(1, minimum) { push(end: total) }
    }

    /// The oldest chunk waiting, which the engine transcribes next.
    public mutating func take() -> Chunk? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// The first sample still needed; everything before it can be forgotten.
    public var keepFrom: Int {
        pending.first?.start ?? max(0, planned - overlap)
    }

    private mutating func push(end: Int) {
        pending.append(Chunk(start: max(0, planned - overlap), fresh: planned, end: end))
        planned = end
        if pending.count > maxPending {
            pending.removeFirst()
            dropped += 1
        }
    }
}

/// The text of overlapping chunks: the words heard twice are kept once.
public enum OverlapText {
    /// `text` without the words at its start that `previous` already ends with.
    /// A word cut at the edge of either chunk doesn't stop the match.
    public static func trim(_ text: String, after previous: String, maxWords: Int = 12) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let next = words.map(normalize)
        let prev = previous.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
        guard !next.isEmpty, !prev.isEmpty else { return words.joined(separator: " ") }
        var cut = 0
        for k in stride(from: min(maxWords, prev.count, next.count), through: 1, by: -1) {
            if Array(prev.suffix(k)) == Array(next.prefix(k)) {
                cut = k
                break
            }
            guard k >= 2 else { continue }
            // The last word of the previous chunk was cut short: "Fri" then "Friday".
            if prev.count > k, next.count > k, Array(prev.dropLast().suffix(k)) == Array(next.prefix(k)),
               let last = prev.last, !last.isEmpty, next[k].hasPrefix(last) {
                cut = k + 1
                break
            }
            // The first word of this chunk is the tail of a word cut short.
            if next.count > k, Array(prev.suffix(k)) == Array(next.dropFirst().prefix(k)) {
                cut = k + 1
                break
            }
        }
        return words.dropFirst(cut).joined(separator: " ")
    }

    /// What was said, without the notes whisper adds for sounds: "[BLANK_AUDIO]", "(music)".
    public static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// 16-bit mono PCM as the live engines handle it.
public enum ChunkAudio {
    /// True when no tenth of a second is louder than `thresholdDB` (RMS, dBFS), so there
    /// is no speech worth transcribing.
    public static func isSilent(_ samples: [Int16], sampleRate: Int, thresholdDB: Double = -45) -> Bool {
        let window = max(1, sampleRate / 10)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + window)
            var sum = 0.0
            for i in index..<end {
                let v = Double(samples[i]) / 32768
                sum += v * v
            }
            let rms = (sum / Double(end - index)).squareRoot()
            if SilenceTrimmer.decibels(Float(rms)) >= thresholdDB { return false }
            index = end
        }
        return true
    }

    /// The samples as a WAV file.
    public static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16))
        put(UInt16(1))
        put(UInt16(1))
        put(UInt32(sampleRate))
        put(UInt32(sampleRate * 2))
        put(UInt16(2))
        put(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        put(bytes)
        for sample in samples { put(sample) }
        return data
    }
}
