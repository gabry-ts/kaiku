import Foundation

/// A setting that search can find: a row or group of a settings pane, with the words
/// people may type for it.
public struct SettingsSearchEntry: Sendable, Equatable {
    /// Where it lives, opaque to the search (the app's pane and anchor).
    public let target: String
    public let pane: String
    public let group: String
    public let title: String
    /// Synonyms and related words, like "hotkey" for a shortcut.
    public let keywords: [String]

    public init(target: String, pane: String, group: String, title: String, keywords: [String] = []) {
        self.target = target
        self.pane = pane
        self.group = group
        self.title = title
        self.keywords = keywords
    }
}

/// A search result: the entry, and the synonym it was found by when not by its title.
public struct SettingsSearchHit: Sendable, Equatable {
    public let entry: SettingsSearchEntry
    public let synonym: String?
    let score: Int
}

/// Finds settings by words, ignoring case and accents. Every word typed must match the start
/// of a word of the entry. Titles rank first, starting with the query best; then synonyms;
/// then the group and pane; ties keep the order of the index.
public enum SettingsSearch {
    public static func search(_ query: String, in entries: [SettingsSearchEntry]) -> [SettingsSearchHit] {
        let words = tokens(query)
        guard !words.isEmpty else { return [] }
        let phrase = fold(query).trimmingCharacters(in: .whitespaces)
        var hits: [(hit: SettingsSearchHit, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            if let hit = match(entry, words: words, phrase: phrase) { hits.append((hit, index)) }
        }
        return hits.sorted { ($0.hit.score, -$0.index) > ($1.hit.score, -$1.index) }.map(\.hit)
    }

    private static func match(_ entry: SettingsSearchEntry, words: [String], phrase: String) -> SettingsSearchHit? {
        let title = tokens(entry.title)
        let place = tokens(entry.group) + tokens(entry.pane)
        let keywords = entry.keywords.map { (raw: $0, tokens: tokens($0)) }
        var score = 0
        var synonym: String?
        var fromTitle = 0
        for word in words {
            if title.contains(where: { $0.hasPrefix(word) }) {
                fromTitle += 1
            } else if let k = keywords.first(where: { $0.tokens.contains { $0.hasPrefix(word) } }) {
                synonym = synonym ?? k.raw
            } else if place.contains(where: { $0.hasPrefix(word) }) {
                score -= 1
            } else {
                return nil
            }
        }
        if fromTitle == words.count {
            score += fold(entry.title).hasPrefix(phrase) ? 400 : 300
            synonym = nil
        } else if fromTitle > 0 {
            score += 250
        } else if synonym != nil {
            score += 200
        } else {
            score += 100
        }
        return SettingsSearchHit(entry: entry, synonym: synonym, score: score)
    }

    /// Lowercased, without accents.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The words of `text`, folded.
    public static func tokens(_ text: String) -> [String] {
        fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Ranges of `text` whose words start with one of the words of `query`, to highlight them.
    public static func highlights(in text: String, query: String) -> [Range<String.Index>] {
        let words = tokens(query)
        guard !words.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i].isLetter || text[i].isNumber else { i = text.index(after: i); continue }
            var end = i
            while end < text.endIndex, text[end].isLetter || text[end].isNumber { end = text.index(after: end) }
            let word = fold(String(text[i..<end]))
            if let w = words.filter({ word.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
                ranges.append(i..<text.index(i, offsetBy: min(w.count, text.distance(from: i, to: end))))
            }
            i = end
        }
        return ranges
    }
}
