import Foundation

/// A call's transcript, to paste into the prompt of an HTTP API.
public struct ChatContextCall: Equatable, Sendable {
    public var call: ChatCall
    public var transcript: String

    public init(call: ChatCall, transcript: String) {
        self.call = call
        self.transcript = transcript
    }
}

/// A call's files, for a command-line tool that reads them itself.
public struct ChatCallFiles: Equatable, Sendable {
    public var call: ChatCall
    public var transcriptPath: String
    public var summaryPath: String?

    public init(call: ChatCall, transcriptPath: String, summaryPath: String? = nil) {
        self.call = call
        self.transcriptPath = transcriptPath
        self.summaryPath = summaryPath
    }
}

/// The transcripts that fit in a provider's context.
public struct ChatPacking: Equatable, Sendable {
    /// Oldest first.
    public var included: [ChatContextCall]
    /// Older calls that didn't fit, newest first.
    public var omitted: [ChatCall]
    /// True when the only call sent was cut to fit.
    public var truncated: Bool
}

/// Prompts for chatting with calls: the instructions, the calls as context and the
/// conversation so far.
public enum ChatPrompt {
    /// Messages of the conversation sent with each question.
    public static let historyCount = 12
    /// Longest conversation sent with each question, in characters.
    public static let historyCharacters = 24_000
    public static let truncatedNote = "[Rest of the call left out]"

    /// The short id a call is cited by, the same in every chat: from its folder name,
    /// which never changes.
    public static func ref(forFolderName name: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "c" + String(String(hash, radix: 16).suffix(6)).leftPadded(to: 6)
    }

    /// Rough token count of a text: about four characters each.
    public static func estimatedTokens(characters: Int) -> Int {
        (characters + 3) / 4
    }

    public static func instructions(readsFiles: Bool, exampleRef: String = "c3fa9b2") -> String {
        var text = """
        You answer questions about the user's recorded calls, using only what was said in them. Answer in the language of the question, concisely, in Markdown: short paragraphs and "- " bullets, no tables.
        Back up what you say with citations in the form [call-id HH:MM:SS]: the id of the call and the time of the transcript line, e.g. [\(exampleRef) 00:12:34]. Put them right after the sentence they support; several go in one pair of brackets, separated by semicolons. Only cite ids and times that appear in the calls.
        If the calls don't say, answer that they don't. Never guess or use outside knowledge.
        """
        if readsFiles {
            text += "\nThe transcripts are Markdown files on this Mac, listed below with the call summary when there is one. Read the ones you need with your file tools before answering; each transcript line starts with its time as [HH:MM:SS]. Only read these files and never change any file."
        } else {
            text += "\nThe transcripts are below, one <call> each; each line starts with its time as [HH:MM:SS]."
        }
        return text
    }

    /// What a call is, for the context: `"Weekly sync", 2026-09-23 14:30, 00:32:10`.
    public static func describe(_ call: ChatCall) -> String {
        "\"\(call.title)\", \(dateText(call.date)), \(TranscriptFormatter.timestamp(call.duration))"
    }

    /// The turns of a transcript.md, without the title and details above them.
    public static func transcriptBody(_ markdown: String) -> String {
        guard let rule = markdown.range(of: "\n---\n") else { return markdown.trimmingCharacters(in: .whitespacesAndNewlines) }
        return markdown[rule.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One call as pasted in the context.
    public static func block(_ call: ChatContextCall) -> String {
        let title = call.call.title.replacingOccurrences(of: "\"", with: "'")
        return """
        <call id="\(call.call.ref)" title="\(title)" date="\(dateText(call.call.date))" duration="\(TranscriptFormatter.timestamp(call.call.duration))">
        \(call.transcript)
        </call>
        """
    }

    /// The most recent calls whose transcripts fit in `budgetCharacters`. When even the
    /// most recent one doesn't fit, its start is sent alone.
    public static func pack(_ calls: [ChatContextCall], budgetCharacters: Int) -> ChatPacking {
        let newest = calls.sorted { $0.call.date > $1.call.date }
        var included: [ChatContextCall] = []
        var used = 0
        for call in newest {
            let size = block(call).count + 2
            guard used + size <= budgetCharacters else { break }
            included.append(call)
            used += size
        }
        var truncated = false
        if included.isEmpty, var first = newest.first {
            let overhead = block(ChatContextCall(call: first.call, transcript: "")).count + truncatedNote.count + 4
            let keep = max(0, budgetCharacters - overhead)
            var text = String(first.transcript.prefix(keep))
            // End on a whole line.
            if let newline = text.lastIndex(of: "\n") { text = String(text[..<newline]) }
            first.transcript = text + "\n\n" + truncatedNote
            included = [first]
            truncated = true
        }
        let sent = Set(included.map(\.call.ref))
        return ChatPacking(included: included.reversed(), omitted: newest.map(\.call).filter { !sent.contains($0.ref) },
                           truncated: truncated)
    }

    /// The system prompt for an HTTP API: instructions, then the transcripts that fit.
    public static func apiSystem(_ packing: ChatPacking, asksTitle: Bool = false) -> String {
        var text = instructions(readsFiles: false, exampleRef: packing.included.first?.call.ref ?? "c3fa9b2")
        if asksTitle { text += "\n" + ChatTitle.instruction }
        if !packing.omitted.isEmpty {
            text += "\nOnly the most recent calls fit; these older ones were left out, so say so if the question is about them: "
                + packing.omitted.map { "\($0.ref) " + describe($0) }.joined(separator: "; ") + "."
        }
        text += "\n\nCalls:\n\n" + packing.included.map(block).joined(separator: "\n\n")
        return text
    }

    /// The whole prompt for a command-line tool, which keeps nothing between questions:
    /// instructions, the files of each call, the conversation so far and the question.
    public static func cliPrompt(files: [ChatCallFiles], history: [ChatMessage], question: String,
                                 asksTitle: Bool = false) -> String {
        var text = instructions(readsFiles: true, exampleRef: files.first?.call.ref ?? "c3fa9b2")
        if asksTitle { text += "\n" + ChatTitle.instruction }
        text += "\n\nCalls:\n"
        for f in files {
            text += "- \(f.call.ref): \(describe(f.call))\n  Transcript: \(f.transcriptPath)\n"
            if let summary = f.summaryPath { text += "  Summary: \(summary)\n" }
        }
        if !history.isEmpty {
            text += "\nConversation so far:\n" + history.map { m in
                (m.role == .user ? "User: " : "Assistant: ") + m.text
            }.joined(separator: "\n\n") + "\n"
        }
        text += "\nQuestion: \(question)"
        return text
    }

    /// The end of the conversation to send along: at most `count` messages and `characters`
    /// characters, starting with a question.
    public static func recent(_ messages: [ChatMessage], count: Int = historyCount,
                              characters: Int = historyCharacters) -> [ChatMessage] {
        var kept: [ChatMessage] = []
        var used = 0
        for message in messages.reversed() {
            guard kept.count < count, used + message.text.count <= characters else { break }
            kept.insert(message, at: 0)
            used += message.text.count
        }
        while let first = kept.first, first.role != .user { kept.removeFirst() }
        return kept
    }

    static func dateText(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: date)
    }
}

/// A moment of a call cited in an answer; no time means the whole call.
public struct ChatCitation: Equatable, Sendable {
    public var ref: String
    public var time: Double?

    public init(ref: String, time: Double?) {
        self.ref = ref
        self.time = time
    }
}

/// Finds citations like `[c3fa9b2 00:12:34]` or `[c3fa9b2 12:34; c1d2e3f 01:02:03]` in
/// answers and turns them into links.
public enum ChatCitations {
    public static let scheme = "kaiku-chat"
    private static let token = try! NSRegularExpression(pattern: #"c[0-9a-f]{6}\b|(?:\d{1,2}:)?\d{1,2}:\d{2}"#,
                                                        options: [.caseInsensitive])
    private static let bracket = try! NSRegularExpression(pattern: #"\[([^\[\]\n]{7,300})\]"#)

    /// The citations in the text between a pair of brackets, nil when it is anything else.
    public static func parse(_ group: String) -> [ChatCitation]? {
        let ns = group as NSString
        let matches = token.matches(in: group, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        // Nothing but separators between the ids and times.
        var rest = group
        for m in matches.reversed() {
            guard let r = Range(m.range, in: rest) else { return nil }
            rest.replaceSubrange(r, with: " ")
        }
        guard rest.allSatisfy({ $0.isWhitespace || ",;@&–-".contains($0) }) else { return nil }

        var citations: [ChatCitation] = []
        var current: String?
        var timed = false
        for m in matches {
            let text = ns.substring(with: m.range)
            if text.lowercased().hasPrefix("c") {
                if let current, !timed { citations.append(ChatCitation(ref: current, time: nil)) }
                current = text.lowercased()
                timed = false
            } else {
                guard let current, let time = seconds(text) else { return nil }
                citations.append(ChatCitation(ref: current, time: time))
                timed = true
            }
        }
        if let current, !timed { citations.append(ChatCitation(ref: current, time: nil)) }
        return citations
    }

    /// Every bracketed group of citations, with where it is in `text`.
    public static func find(_ text: String) -> [(range: Range<String.Index>, citations: [ChatCitation])] {
        bracket.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m -> (range: Range<String.Index>, citations: [ChatCitation])? in
            guard let range = Range(m.range, in: text), let inner = Range(m.range(at: 1), in: text),
                  let citations = parse(String(text[inner])) else { return nil }
            return (range: range, citations: citations)
        }
    }

    /// The text with each citation replaced by a Markdown link to `url(for:)`, labelled
    /// with the call title and time. Citations of unknown calls (`title` returns nil) stay as text.
    /// Without `parentheses` the links of a group are only separated by spaces, to be shown as chips.
    public static func linked(_ text: String, parentheses: Bool = true, title: (String) -> String?) -> String {
        var out = text
        for found in find(text).reversed() {
            let parts = found.citations.map { c -> String in
                let time = c.time.map(shortTime)
                guard let name = title(c.ref) else { return [c.ref, time].compactMap { $0 }.joined(separator: " ") }
                let label = [escape(shortened(name)), time].compactMap { $0 }.joined(separator: " · ")
                return "[\(label)](\(url(for: c).absoluteString))"
            }
            out.replaceSubrange(found.range, with: parentheses ? "(" + parts.joined(separator: ", ") + ")"
                                                               : parts.joined(separator: " "))
        }
        return out
    }

    public static func url(for citation: ChatCitation) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "cite"
        parts.queryItems = [URLQueryItem(name: "call", value: citation.ref)]
            + (citation.time.map { [URLQueryItem(name: "t", value: String(Int($0)))] } ?? [])
        return parts.url!
    }

    /// The citation behind a link made by `linked`, nil for other links.
    public static func citation(from url: URL) -> ChatCitation? {
        guard url.scheme == scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let ref = parts.queryItems?.first(where: { $0.name == "call" })?.value, !ref.isEmpty else { return nil }
        let time = parts.queryItems?.first(where: { $0.name == "t" })?.value.flatMap { Double($0) }
        return ChatCitation(ref: ref, time: time)
    }

    /// Seconds in `HH:MM:SS` or `MM:SS`.
    public static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        guard values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return Double(values.reduce(0) { $0 * 60 + $1 })
    }

    /// `12:34`, or `1:02:03` past the hour.
    public static func shortTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func shortened(_ title: String) -> String {
        title.count > 32 ? String(title.prefix(31)).trimmingCharacters(in: .whitespaces) + "…" : title
    }

    /// Brackets would end the link text early.
    private static func escape(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }
}

/// The short title of a chat, asked of the provider along with the first answer.
public enum ChatTitle {
    public static let instruction = "After the answer, on a last line of its own, write \"Title: \" followed by a title of 3 to 6 words for this conversation, in the language of the question."

    private static let longest = 60

    /// The answer without its title line, and the title when there is one.
    public static func split(_ answer: String) -> (text: String, title: String?) {
        var lines = answer.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last, let title = title(in: last) else { return (answer, nil) }
        lines.removeLast()
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, title.isEmpty ? nil : title)
    }

    /// The answer so far, without a title line being written at its end.
    public static func hidingTitle(_ partial: String) -> String {
        guard let newline = partial.lastIndex(of: "\n") else { return partial }
        let last = partial[partial.index(after: newline)...].trimmingCharacters(in: .whitespaces)
        let bare = last.replacingOccurrences(of: "*", with: "").lowercased()
        guard !bare.isEmpty, "title:".hasPrefix(bare) || bare.hasPrefix("title:") else { return partial }
        return String(partial[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title in a `Title: …` line, cleaned of Markdown and quotes; nil for other lines.
    static func title(in line: String) -> String? {
        let bare = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        guard bare.lowercased().hasPrefix("title:") else { return nil }
        var title = bare.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`_#.").union(.whitespaces))
        return title.count > longest ? ChatConversation.title(from: title) : title
    }
}

/// The calls of a period, for choosing what a chat is about.
public enum ChatPeriod {
    /// From the start of the day `days - 1` days ago to the end of today.
    public static func lastDays(_ days: Int, now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        return start...endOfDay(now, calendar: calendar)
    }

    /// Whole days from `from` to `to`, in either order.
    public static func range(from: Date, to: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let (a, b) = from <= to ? (from, to) : (to, from)
        return calendar.startOfDay(for: a)...endOfDay(b, calendar: calendar)
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return (calendar.date(byAdding: .day, value: 1, to: start) ?? start).addingTimeInterval(-0.001)
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
