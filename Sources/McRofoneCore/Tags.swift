import Foundation

/// Tags (e.g. project names) attached to calls.
public enum Tags {
    /// Trims, drops empty tags and duplicates (case-insensitive, first spelling wins).
    public static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).joined(separator: " ")
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// Every tag used, most recently used first. `calls` are (date, tags) pairs in any order.
    public static func byRecency(_ calls: [(date: Date, tags: [String])]) -> [String] {
        normalize(calls.sorted { $0.date > $1.date }.flatMap(\.tags))
    }

    /// Known tags that start with (or else contain) `text`, excluding ones already chosen.
    public static func suggestions(for text: String, known: [String], excluding chosen: [String], limit: Int = 6) -> [String] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        let taken = Set(chosen.map { $0.lowercased() })
        let available = known.filter { !taken.contains($0.lowercased()) }
        guard !q.isEmpty else { return Array(available.prefix(limit)) }
        let prefix = available.filter { $0.lowercased().hasPrefix(q) }
        let contains = available.filter { !$0.lowercased().hasPrefix(q) && $0.lowercased().contains(q) }
        return Array((prefix + contains).prefix(limit))
    }

    public static func contains(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}
