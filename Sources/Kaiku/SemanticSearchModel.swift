import Foundation
import KaikuCore

/// Smart search of the library: keeps the passage vectors of the calls up to date in the
/// background and finds the passages closest in meaning to a query.
@MainActor
final class SemanticSearchModel: ObservableObject {
    /// A passage found for the query, with the call it is in.
    struct Hit: Identifiable {
        let folder: RecordingFolder
        let title: String
        let date: Date
        let passage: Passage
        let score: Float
        var id: String { "\(folder.key)-\(passage.start)" }
    }

    struct Progress: Equatable {
        let done: Int
        let total: Int
    }

    @Published private(set) var results: [Hit] = []
    @Published private(set) var isSearching = false
    /// Calls indexed so far while indexing runs, nil otherwise.
    @Published private(set) var progress: Progress?
    /// True when this Mac has no sentence embedding model to search with.
    @Published private(set) var unavailable = false

    private let embedder = NLSentenceEmbedder()
    private let cache = IndexCache()
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var query = ""

    /// True once Smart search was turned on, in the library or in Settings: from then on new
    /// transcriptions are indexed too. Turning it off in Settings stops indexing.
    var isActive: Bool {
        get { AppSettings.defaults.bool(forKey: Keys.smartSearchUsed) }
        set { AppSettings.defaults.set(newValue, forKey: Keys.smartSearchUsed) }
    }

    /// Turned off in Settings: indexing stops, the index already built stays.
    func deactivate() {
        isActive = false
        indexTask?.cancel()
        indexTask = nil
        progress = nil
    }

    /// Called when Smart search is turned on: checks the model and indexes the calls.
    func activate() {
        isActive = true
        let embedder = embedder
        Task {
            unavailable = await Task.detached { !embedder.supports(language: "en") }.value
            if !unavailable { indexPending() }
        }
    }

    /// Indexes, at low priority, every call with a transcript and no up to date index. Does
    /// nothing until Smart search was used once.
    func indexPending() {
        guard isActive, indexTask == nil else { return }
        let base = AppSettings.baseFolder
        let embedder = embedder
        indexTask = Task {
            var attempted = Set<String>()
            while !Task.isCancelled {
                let pending = await Task.detached(priority: .utility) {
                    CallLibrary(base: base).calls().filter { SemanticIndexer.needsIndexing($0.folder, meta: $0.meta, embedder: embedder) }
                }.value.filter { !attempted.contains($0.id) }
                if pending.isEmpty { break }
                for (n, call) in pending.enumerated() {
                    guard !Task.isCancelled else { break }
                    progress = Progress(done: n, total: pending.count)
                    attempted.insert(call.id)
                    await Task.detached(priority: .background) {
                        SemanticIndexer.build(call.folder, meta: call.meta, embedder: embedder)
                    }.value
                }
            }
            guard !Task.isCancelled else { return }
            progress = nil
            indexTask = nil
            if !query.isEmpty { search(query) }
        }
    }

    /// Finds the passages closest in meaning to `text`, shortly after the last change to it.
    func search(_ text: String) {
        searchTask?.cancel()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let query = query, base = AppSettings.baseFolder, embedder = embedder, cache = cache
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { () -> [Hit] in
                let calls = CallLibrary(base: base).calls()
                let indexes = calls.compactMap { c in cache.index(for: c.folder).map { (callID: c.id, index: $0) } }
                var vectors: [String: [Float]] = [:]
                for language in Set(indexes.map(\.index.language)) {
                    if let v = embedder.embed(query, language: language) { vectors[language] = v }
                }
                let byID = Dictionary(calls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                return SemanticRanker.rank(queries: vectors, indexes: indexes).compactMap { m in
                    byID[m.callID].map { Hit(folder: $0.folder, title: $0.meta.title, date: $0.meta.date, passage: m.passage, score: m.score) }
                }
            }.value
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}

/// Indexes read from disk, kept until their file changes.
private final class IndexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (stamp: Date, index: SemanticIndex)] = [:]

    func index(for folder: RecordingFolder) -> SemanticIndex? {
        let stamp = (try? folder.embeddingsURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let stamp else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[folder.key], cached.stamp == stamp { return cached.index }
        guard let index = folder.loadSemanticIndex() else { return nil }
        entries[folder.key] = (stamp, index)
        return index
    }
}
