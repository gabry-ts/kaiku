import Foundation
import NaturalLanguage

/// Language codes as the embedding models know them.
public enum TextLanguage {
    /// `it-IT`, `IT` and `it_IT` give `it`.
    public static func code(_ language: String) -> String {
        String(language.lowercased().prefix { $0 != "-" && $0 != "_" })
    }

    /// The dominant language of `text`, or nil when it can't tell.
    public static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        return recognizer.dominantLanguage?.rawValue
    }
}

/// Builds, stores and loads the semantic index of a call.
public enum SemanticIndexer {
    /// The language to embed a call in: the one it was transcribed in, else the detected one,
    /// else the language of the text, else English; the first the embedder has a model for.
    public static func language(for meta: RecordingMeta, sample: String, embedder: TextEmbedder) -> String? {
        var candidates = [meta.language, meta.detectedLanguage ?? ""].filter { !$0.isEmpty && $0 != "auto" }
        candidates.append(TextLanguage.detect(sample) ?? "")
        candidates.append("en")
        return candidates.map(TextLanguage.code).first { !$0.isEmpty && embedder.supports(language: $0) }
    }

    /// The passages of the call's segments.json, nil when it has none.
    public static func passages(of folder: RecordingFolder, meta: RecordingMeta) -> [Passage]? {
        guard let raw = folder.loadSegments() else { return nil }
        let passages = PassageChunker.chunks(from: TranscriptWriter.displaySegments(meta: meta, rawSegments: raw))
        return passages.isEmpty ? nil : passages
    }

    /// The stored index when it still matches the call, else nil.
    public static func fresh(for folder: RecordingFolder, meta: RecordingMeta, embedder: TextEmbedder) -> SemanticIndex? {
        guard let index = folder.loadSemanticIndex(), let passages = passages(of: folder, meta: meta),
              let language = language(for: meta, sample: passages[0].text, embedder: embedder),
              !index.isStale(language: language, fingerprint: SemanticIndex.fingerprint(of: passages))
        else { return nil }
        return index
    }

    /// True when the call has a transcript but no up to date index.
    public static func needsIndexing(_ folder: RecordingFolder, meta: RecordingMeta, embedder: TextEmbedder) -> Bool {
        passages(of: folder, meta: meta) != nil && fresh(for: folder, meta: meta, embedder: embedder) == nil
    }

    /// Embeds the call's passages and saves the index. Nil when there is nothing to index or
    /// no model for its language.
    @discardableResult
    public static func build(_ folder: RecordingFolder, meta: RecordingMeta, embedder: TextEmbedder) -> SemanticIndex? {
        guard let passages = passages(of: folder, meta: meta),
              let language = language(for: meta, sample: passages[0].text, embedder: embedder) else { return nil }
        let entries = passages.compactMap { p in
            embedder.embed(p.text, language: language).map { SemanticIndex.Entry(passage: p, vector: $0) }
        }
        guard !entries.isEmpty else { return nil }
        let index = SemanticIndex(language: language, fingerprint: SemanticIndex.fingerprint(of: passages), entries: entries)
        try? folder.saveSemanticIndex(index)
        return index
    }
}

public extension RecordingFolder {
    /// The call's passage vectors (hidden, like the other working files).
    static let embeddingsName = ".embeddings.json"
    var embeddingsURL: URL { url.appendingPathComponent(Self.embeddingsName) }

    func loadSemanticIndex() -> SemanticIndex? {
        guard let data = try? Data(contentsOf: embeddingsURL) else { return nil }
        return try? JSONDecoder().decode(SemanticIndex.self, from: data)
    }

    func saveSemanticIndex(_ index: SemanticIndex) throws {
        try JSONEncoder().encode(index).write(to: embeddingsURL, options: .atomic)
    }
}
