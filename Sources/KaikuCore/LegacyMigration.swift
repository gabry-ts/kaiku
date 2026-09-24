import Foundation

/// A folder that was moved during the migration from the previous app name.
public struct PathMove: Equatable, Sendable {
    public var from: String
    public var to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Pure rules of the one-time migration from the previous app name.
public enum LegacyMigration {
    /// What to do with an old data folder.
    public enum FolderAction: Equatable, Sendable {
        /// Only the old folder exists: move it to the new location.
        case move
        /// Both exist: leave everything where it is and keep using the old folder.
        case keepOld
        /// Nothing to migrate.
        case none
    }

    public static func folderAction(oldExists: Bool, newExists: Bool) -> FolderAction {
        guard oldExists else { return .none }
        return newExists ? .keepOld : .move
    }

    /// True when `path` (absolute or starting with `~`) is `folder`.
    public static func isSame(_ path: String, as folder: String, home: String) -> Bool {
        normalize(expand(path, home: home)) == normalize(folder)
    }

    /// The path rewritten into the new location when it lies inside a moved folder,
    /// or nil when it is not affected. A `~` prefix is kept.
    public static func rewrite(_ path: String, moves: [PathMove], home: String) -> String? {
        let tilde = path == "~" || path.hasPrefix("~/")
        let absolute = normalize(expand(path, home: home))
        for move in moves {
            let from = normalize(move.from)
            let to = normalize(move.to)
            guard absolute == from || absolute.hasPrefix(from + "/") else { continue }
            let rewritten = to + absolute.dropFirst(from.count)
            return tilde ? abbreviate(rewritten, home: home) : rewritten
        }
        return nil
    }

    /// The entries of a defaults dictionary whose string or string-array values point
    /// into a moved folder, with the rewritten values. Unaffected keys are left out.
    public static func rewrittenValues(_ values: [String: Any], moves: [PathMove], home: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in values {
            if let s = value as? String, let r = rewrite(s, moves: moves, home: home) {
                out[key] = r
            } else if let a = value as? [String] {
                let r = a.map { rewrite($0, moves: moves, home: home) }
                if r.contains(where: { $0 != nil }) {
                    out[key] = zip(a, r).map { $1 ?? $0 }
                }
            }
        }
        return out
    }

    private static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return normalize(home) + path.dropFirst(1) }
        return path
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        let h = normalize(home)
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    /// Removes trailing slashes (except for the root).
    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
