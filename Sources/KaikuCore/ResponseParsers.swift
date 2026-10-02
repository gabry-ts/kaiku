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

    // MARK: whisper.cpp (-oj, or -ojf with the tokens of each segment)

    private struct WhisperCppOutput: Decodable {
        struct Result: Decodable { let language: String? }
        struct Offsets: Decodable { let from: Double; let to: Double }
        struct Token: Decodable {
            let text: String
            let offsets: Offsets?
            /// DTW time in centiseconds, -1 or absent without `--dtw`.
            let t_dtw: Double?
        }
        struct Item: Decodable {
            let offsets: Offsets
            let text: String
            let tokens: [Token]?
        }
        let result: Result?
        let transcription: [Item]
    }

    public static func whisperCpp(_ data: Data) throws -> TranscriptionResult {
        // Token texts can hold half of a multibyte character, which is not valid UTF-8:
        // replace those bytes rather than failing the whole transcript.
        let valid = Data(String(decoding: data, as: UTF8.self).utf8)
        let out: WhisperCppOutput
        do { out = try JSONDecoder().decode(WhisperCppOutput.self, from: valid) }
        catch { throw ParseError.invalid("whisper.cpp JSON: \(error)") }
        let segs = out.transcription.map { item in
            Segment(start: item.offsets.from / 1000, end: item.offsets.to / 1000, text: item.text,
                    words: item.tokens.flatMap { whisperCppWords($0, text: item.text, segmentStart: item.offsets.from / 1000, segmentEnd: item.offsets.to / 1000) })
        }
        return TranscriptionResult(segments: segs, detectedLanguage: out.result?.language)
    }

    /// Joins whisper.cpp tokens into words: a token starting with a space starts a new word,
    /// special tokens like `[_BEG_]` or `[_TT_42]` are skipped. Nil when the tokens have no times
    /// (older whisper.cpp, or plain `-oj` output). With DTW times (`--dtw`) a word starts at the
    /// DTW time of its first timed token and ends where the next word starts, since the token
    /// offsets are coarse.
    private static func whisperCppWords(_ tokens: [WhisperCppOutput.Token], text: String,
                                        segmentStart: Double, segmentEnd: Double) -> [Segment.Word]? {
        var words: [Segment.Word] = []
        var dtwStarts: [Double?] = []
        var startsWord = true
        for token in tokens {
            let t = token.text
            if t.hasPrefix("[_") || t.hasPrefix("<|") { continue }
            var timed = false
            var start = 0.0
            var end = 0.0
            if let o = token.offsets, o.from >= 0, o.to >= o.from {
                timed = true
                start = o.from / 1000
                end = o.to / 1000
            }
            if t.hasPrefix(" ") || words.isEmpty || startsWord {
                // A token without times can only continue a timed word.
                guard timed else { continue }
                words.append(Segment.Word(start: start, end: end, text: t))
                dtwStarts.append(nil)
            } else {
                words[words.count - 1].text += t
                if timed { words[words.count - 1].end = max(words[words.count - 1].end, end) }
            }
            if let d = token.t_dtw, d >= 0, !dtwStarts.isEmpty, dtwStarts[dtwStarts.count - 1] == nil {
                dtwStarts[dtwStarts.count - 1] = d / 100
            }
            startsWord = t.hasSuffix(" ")
        }
        var kept: [Segment.Word] = []
        var keptDTW: [Double?] = []
        for (i, w) in words.enumerated() {
            var c = w
            c.text = w.text.replacingOccurrences(of: "\u{FFFD}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if c.text.isEmpty { continue }
            kept.append(c)
            keptDTW.append(dtwStarts[i])
        }
        words = kept
        if keptDTW.contains(where: { $0 != nil }) {
            let lo = segmentStart, hi = max(segmentEnd, segmentStart)
            let starts = words.indices.map { min(max(keptDTW[$0] ?? words[$0].start, lo), hi) }
            for i in words.indices {
                words[i].start = starts[i]
                words[i].end = max(starts[i], i + 1 < words.count ? min(starts[i + 1], hi) : hi)
            }
        }
        // The segment text has the exact characters (a token may hold half of one): use it
        // when it splits into the same words.
        let spoken = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if spoken.count == words.count {
            for i in words.indices { words[i].text = spoken[i] }
        }
        return words.isEmpty ? nil : words
    }

    /// The `--dtw` preset of whisper.cpp for a model file such as `ggml-large-v3-turbo-q5_0.bin`,
    /// nil when the model is not a known one.
    public static func whisperCppDTWPreset(modelFile: String) -> String? {
        var name = (modelFile as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("ggml-") { name.removeFirst(5) }
        if name.hasSuffix(".bin") { name.removeLast(4) }
        // Longest names first so that `large-v3-turbo` is not taken for `large-v3`.
        let presets = ["large-v3-turbo": "large.v3.turbo", "large-v3": "large.v3", "large-v2": "large.v2",
                       "large-v1": "large.v1", "medium.en": "medium.en", "medium": "medium",
                       "small.en": "small.en", "small": "small", "base.en": "base.en", "base": "base",
                       "tiny.en": "tiny.en", "tiny": "tiny"]
        for (key, preset) in presets.sorted(by: { $0.key.count > $1.key.count }) {
            guard name.hasPrefix(key) else { continue }
            let rest = name.dropFirst(key.count)
            // Only a quantisation suffix (`-q5_0`, `-q8_0`) may follow.
            if rest.isEmpty || rest.hasPrefix("-q") { return preset }
        }
        return nil
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
        /// Present with `timestamp_granularities[]=word` (whisper models, verbose_json).
        struct Word: Decodable {
            let word: String
            let start: Double
            let end: Double
        }
        let text: String?
        let language: String?
        let duration: Double?
        let segments: [Seg]?
        let words: [Word]?
    }

    /// Parses `json`, `verbose_json` or `diarized_json` responses.
    /// `chunkDuration` is used as the end time when the response has no timestamps.
    public static func openAI(_ data: Data, offset: Double, chunkDuration: Double) throws -> TranscriptionResult {
        let out: OpenAIOutput
        do { out = try JSONDecoder().decode(OpenAIOutput.self, from: data) }
        catch { throw ParseError.invalid("OpenAI-compatible JSON: \(error)") }
        let words = (out.words ?? []).compactMap { w -> Segment.Word? in
            let text = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, w.start.isFinite, w.end.isFinite, w.end >= w.start else { return nil }
            return Segment.Word(start: offset + w.start, end: offset + w.end, text: text)
        }
        if let segs = out.segments, !segs.isEmpty {
            let mapped = segs.map {
                Segment(start: offset + ($0.start ?? 0), end: offset + ($0.end ?? chunkDuration), speaker: $0.speaker, text: $0.text)
            }
            return TranscriptionResult(segments: assign(words, to: mapped), detectedLanguage: out.language)
        }
        let text = (out.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = text.isEmpty ? [] : [Segment(start: offset, end: offset + chunkDuration, text: text,
                                               words: words.isEmpty ? nil : words)]
        return TranscriptionResult(segments: segs, detectedLanguage: out.language)
    }

    /// Gives each word to the segment its middle falls in, or else to the nearest one.
    static func assign(_ words: [Segment.Word], to segments: [Segment]) -> [Segment] {
        guard !words.isEmpty, !segments.isEmpty else { return segments }
        var out = segments
        for w in words {
            let mid = (w.start + w.end) / 2
            func distance(_ s: Segment) -> Double { mid < s.start ? s.start - mid : (mid > s.end ? mid - s.end : 0) }
            var best = 0
            for i in out.indices.dropFirst() where distance(out[i]) < distance(out[best]) { best = i }
            if out[best].words == nil { out[best].words = [w] } else { out[best].words?.append(w) }
        }
        return out
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
