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

    // MARK: Alibaba Cloud Model Studio

    private struct AlibabaChatOutput: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct Annotation: Decodable { let language: String? }
                let content: String?
                let annotations: [Annotation]?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    /// Parses a Qwen3-ASR-Flash `chat/completions` response (text only, no timestamps).
    public static func alibabaChat(_ data: Data, offset: Double, chunkDuration: Double) throws -> TranscriptionResult {
        let out: AlibabaChatOutput
        do { out = try JSONDecoder().decode(AlibabaChatOutput.self, from: data) }
        catch { throw ParseError.invalid("Alibaba Cloud JSON: \(error)") }
        let message = out.choices.first?.message
        let text = (message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = text.isEmpty ? [] : [Segment(start: offset, end: offset + chunkDuration, text: text)]
        return TranscriptionResult(segments: segs, detectedLanguage: message?.annotations?.compactMap(\.language).first)
    }

    private struct AlibabaFileOutput: Decodable {
        struct Transcript: Decodable {
            struct Sentence: Decodable {
                let begin_time: Double
                let end_time: Double
                let text: String
                let speaker_id: Int?
            }
            let text: String?
            let sentences: [Sentence]?
        }
        let transcripts: [Transcript]
    }

    /// Parses the result file of an asynchronous file transcription (times in milliseconds).
    public static func alibabaFile(_ data: Data, diarized: Bool) throws -> TranscriptionResult {
        let out: AlibabaFileOutput
        do { out = try JSONDecoder().decode(AlibabaFileOutput.self, from: data) }
        catch { throw ParseError.invalid("Alibaba Cloud JSON: \(error)") }
        var segs: [Segment] = []
        for transcript in out.transcripts {
            if let sentences = transcript.sentences, !sentences.isEmpty {
                segs += sentences.map {
                    Segment(start: $0.begin_time / 1000, end: $0.end_time / 1000,
                            speaker: diarized ? $0.speaker_id.map { "speaker_\($0)" } : nil, text: $0.text)
                }
            } else if let text = transcript.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                segs.append(Segment(start: 0, end: 0, text: text))
            }
        }
        return TranscriptionResult(segments: segs)
    }
}
