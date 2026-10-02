import Foundation
import NaturalLanguage

/// Sentence embeddings from the NaturalLanguage framework, computed on this Mac.
public final class NLSentenceEmbedder: TextEmbedder, @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String: NLEmbedding?] = [:]

    public init() {}

    private func model(_ language: String) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = models[language] { return cached }
        let loaded = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: language))
        models[language] = .some(loaded)
        return loaded
    }

    public func supports(language: String) -> Bool { model(language) != nil }

    public func embed(_ text: String, language: String) -> [Float]? {
        guard let vector = model(language)?.vector(for: text) else { return nil }
        return vector.map { Float($0) }
    }
}
