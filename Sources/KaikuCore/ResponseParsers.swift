import Foundation

public enum ParseError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let msg): return "Could not parse provider response: \(msg)"
        }
    }
}

/// Parsers for provider JSON responses. Kept free of networking so they can be tested.
public enum ResponseParsers {

    // MARK: whisper.cpp (-oj)

    private struct WhisperCppOutput: Decodable {
        struct Result: Decodable { let language: String? }
        struct Item: Decodable {
            struct Offsets: Decodable { let from: Double; let to: Double }
            let offsets: Offsets
            let text: String
        }
        let result: Result?
        let transcription: [Item]
    }

    public static func whisperCpp(_ data: Data) throws -> TranscriptionResult {
        let out: WhisperCppOutput
        do { out = try JSONDecoder().decode(WhisperCppOutput.self, from: data) }
        catch { throw ParseError.invalid("whisper.cpp JSON: \(error)") }
        let segs = out.transcription.map {
            Segment(start: $0.offsets.from / 1000, end: $0.offsets.to / 1000, text: $0.text)
        }
        return TranscriptionResult(segments: segs, detectedLanguage: out.result?.language)
    }

    // MARK: ElevenLabs Scribe

    private struct ElevenLabsOutput: Decodable {
        struct Word: Decodable {
            let text: String
            let start: Double?
            let end: Double?
            let type: String?
            let speaker_id: String?
        }
        let language_code: String?
        let text: String?
        let words: [Word]?
    }

    public static func elevenLabs(_ data: Data, diarized: Bool) throws -> TranscriptionResult {
        let out: ElevenLabsOutput
        do { out = try JSONDecoder().decode(ElevenLabsOutput.self, from: data) }
        catch { throw ParseError.invalid("ElevenLabs JSON: \(error)") }
        let words: [TimedWord] = (out.words ?? []).compactMap { w in
            guard (w.type ?? "word") == "word", let s = w.start, let e = w.end else { return nil }
            return TimedWord(text: w.text, start: s, end: e, speaker: diarized ? w.speaker_id : nil)
        }
        var segs = TranscriptFormatter.group(words: words)
        if segs.isEmpty, let text = out.text, !text.isEmpty {
            segs = [Segment(start: 0, end: 0, text: text)]
        }
        return TranscriptionResult(segments: segs, detectedLanguage: out.language_code)
    }

    // MARK: OpenAI-compatible (OpenAI, Groq)

    private struct OpenAIOutput: Decodable {
        struct Seg: Decodable {
            let start: Double?
            let end: Double?
            let text: String
            let speaker: String?
        }
        let text: String?
        let language: String?
        let duration: Double?
        let segments: [Seg]?
    }

    /// Parses `json`, `verbose_json` or `diarized_json` responses.
    /// `chunkDuration` is used as the end time when the response has no timestamps.
    public static func openAI(_ data: Data, offset: Double, chunkDuration: Double) throws -> TranscriptionResult {
        let out: OpenAIOutput
        do { out = try JSONDecoder().decode(OpenAIOutput.self, from: data) }
        catch { throw ParseError.invalid("OpenAI-compatible JSON: \(error)") }
        if let segs = out.segments, !segs.isEmpty {
            let mapped = segs.map {
                Segment(start: offset + ($0.start ?? 0), end: offset + ($0.end ?? chunkDuration), speaker: $0.speaker, text: $0.text)
            }
            return TranscriptionResult(segments: mapped, detectedLanguage: out.language)
        }
        let text = (out.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = text.isEmpty ? [] : [Segment(start: offset, end: offset + chunkDuration, text: text)]
        return TranscriptionResult(segments: segs, detectedLanguage: out.language)
    }
}
