import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case md, txt, srt, vtt, docx
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .md: return "Markdown"
        case .txt: return "Plain Text"
        case .srt: return "SubRip Subtitles (SRT)"
        case .vtt: return "WebVTT Subtitles (VTT)"
        case .docx: return "Word Document (DOCX)"
        }
    }
}

/// Everything an export needs, already resolved (speaker names applied).
public struct ExportDocument: Sendable {
    public var title: String
    public var date: Date
    public var durationSeconds: Double
    public var provider: String
    public var language: String
    /// Timed segments with display speaker names, not merged. Used for subtitles.
    public var segments: [Segment]
    public var bookmarks: [Bookmark]
    /// The transcript.md content, used for the Markdown export.
    public var markdown: String?
    public var tags: [String]

    public init(title: String, date: Date, durationSeconds: Double, provider: String, language: String,
                segments: [Segment], bookmarks: [Bookmark] = [], markdown: String? = nil, tags: [String] = []) {
        self.tags = tags
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        self.provider = provider
        self.language = language
        self.segments = segments
        self.bookmarks = bookmarks
        self.markdown = markdown
    }

    /// Speaker turns (consecutive segments of one speaker merged).
    public var turns: [Segment] { TranscriptFormatter.merge(segments) }

    var header: TranscriptFormatter.Header {
        .init(title: title, date: date, durationSeconds: durationSeconds, provider: provider, language: language, audioFiles: [], tags: tags)
    }

    var dateText: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: date)
    }
}

public enum ExportFormatter {
    public static func data(_ doc: ExportDocument, format: ExportFormat) -> Data {
        switch format {
        case .md: return Data((doc.markdown ?? TranscriptFormatter.markdown(header: doc.header, merged: doc.turns, bookmarks: doc.bookmarks)).utf8)
        case .txt: return Data(text(doc).utf8)
        case .srt: return Data(srt(doc).utf8)
        case .vtt: return Data(vtt(doc).utf8)
        case .docx: return docx(doc)
        }
    }

    /// `00:01:02,500` (SRT) or `00:01:02.500` (VTT).
    public static func cueTime(_ seconds: Double, separator: Character) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60,
                      String(separator), ms % 1000)
    }

    /// Cues sorted by start, with a minimum length and no empty text.
    static func cues(_ doc: ExportDocument) -> [(start: Double, end: Double, text: String)] {
        doc.segments
            .map { s in (s, s.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.0.start < $1.0.start }
            .map { s, text in
                let prefix = s.speaker.map { "\($0): " } ?? ""
                return (s.start, max(s.end, s.start + 1), prefix + text)
            }
    }

    public static func srt(_ doc: ExportDocument) -> String {
        cues(doc).enumerated().map { i, c in
            "\(i + 1)\n\(cueTime(c.start, separator: ",")) --> \(cueTime(c.end, separator: ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ doc: ExportDocument) -> String {
        var out = "WEBVTT\n"
        for c in cues(doc) {
            // "-->" is not allowed inside cue text.
            let text = c.text.replacingOccurrences(of: "-->", with: "->")
            out += "\n\(cueTime(c.start, separator: ".")) --> \(cueTime(c.end, separator: "."))\n\(text)\n"
        }
        return out
    }

    public static func text(_ doc: ExportDocument) -> String {
        var lines = [
            doc.title,
            "",
            "Date: \(doc.dateText)",
            "Duration: \(TranscriptFormatter.timestamp(doc.durationSeconds))",
            "Provider: \(doc.provider)",
            "Language: \(doc.language)",
        ]
        if !doc.tags.isEmpty { lines.append("Tags: " + doc.tags.joined(separator: ", ")) }
        lines.append("")
        for item in timeline(doc) {
            switch item {
            case .turn(let s): lines.append("[\(TranscriptFormatter.timestamp(s.start))] \(s.speaker ?? "Unknown"): \(s.text)")
            case .bookmark(let b): lines.append("[\(TranscriptFormatter.timestamp(b.time))] Bookmark: \(b.displayLabel)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    enum TimelineItem {
        case turn(Segment)
        case bookmark(Bookmark)
    }

    /// Speaker turns and bookmarks in time order (a bookmark goes before turns that start after it).
    static func timeline(_ doc: ExportDocument) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var pending = doc.bookmarks.sorted { $0.time < $1.time }[...]
        for turn in doc.turns {
            while let b = pending.first, b.time < turn.start {
                items.append(.bookmark(b))
                pending = pending.dropFirst()
            }
            items.append(.turn(turn))
        }
        items += pending.map { .bookmark($0) }
        return items
    }

    // MARK: DOCX

    public static func docx(_ doc: ExportDocument) -> Data {
        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", contents: Data(contentTypes.utf8))
        zip.add(path: "_rels/.rels", contents: Data(rels.utf8))
        zip.add(path: "word/document.xml", contents: Data(documentXML(doc).utf8))
        return zip.finalized()
    }

    static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    </Types>
    """

    static let rels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    </Relationships>
    """

    public static func documentXML(_ doc: ExportDocument) -> String {
        struct Run { var text: String; var bold = false; var italic = false; var size: Int? = nil; var color: String? = nil }
        func paragraph(_ runs: [Run], spacingAfter: Int = 160) -> String {
            let body = runs.map { r -> String in
                var props = ""
                if r.bold { props += "<w:b/>" }
                if r.italic { props += "<w:i/>" }
                if let c = r.color { props += "<w:color w:val=\"\(c)\"/>" }
                if let s = r.size { props += "<w:sz w:val=\"\(s)\"/>" }
                let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
                return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(xmlEscape(r.text))</w:t></w:r>"
            }.joined()
            return "<w:p><w:pPr><w:spacing w:after=\"\(spacingAfter)\"/></w:pPr>\(body)</w:p>"
        }

        var paras: [String] = [
            paragraph([Run(text: doc.title, bold: true, size: 40)], spacingAfter: 240),
        ]
        for (label, value) in [("Date", doc.dateText), ("Duration", TranscriptFormatter.timestamp(doc.durationSeconds)),
                               ("Provider", doc.provider), ("Language", doc.language)]
            + (doc.tags.isEmpty ? [] : [("Tags", doc.tags.joined(separator: ", "))]) {
            paras.append(paragraph([Run(text: "\(label): ", bold: true, color: "666666"), Run(text: value, color: "666666")], spacingAfter: 40))
        }
        paras.append(paragraph([], spacingAfter: 120))
        for item in timeline(doc) {
            switch item {
            case .turn(let s):
                paras.append(paragraph([
                    Run(text: "[\(TranscriptFormatter.timestamp(s.start))] ", color: "888888"),
                    Run(text: "\(s.speaker ?? "Unknown"): ", bold: true),
                    Run(text: s.text),
                ]))
            case .bookmark(let b):
                paras.append(paragraph([
                    Run(text: "[\(TranscriptFormatter.timestamp(b.time))] ", color: "888888"),
                    Run(text: "Bookmark: \(b.displayLabel)", italic: true, color: "C0392B"),
                ]))
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
        \(paras.joined())\
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>\
        </w:body></w:document>
        """
    }

    /// Escapes XML text and drops characters XML 1.0 does not allow.
    public static func xmlEscape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// Default export file name, e.g. "2026-09-23 Weekly sync.srt".
    public static func fileName(title: String, date: Date, format: ExportFormat) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = "\(df.string(from: date)) \(clean.isEmpty ? "Call" : String(clean.prefix(80)))"
        return "\(base).\(format.fileExtension)"
    }
}
