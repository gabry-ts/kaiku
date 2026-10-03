import Foundation
import UniformTypeIdentifiers

/// Rules for turning audio and video files into calls.
public enum AudioImport {
    /// Kinds of files offered in the Import panel and accepted when dropped.
    public static let contentTypes: [UTType] = [.audio, .movie]

    /// Whether the file looks like audio or video, judged by its extension; web links are
    /// left out. Whether it really holds a readable audio track is only known once it is opened.
    public static func isSupported(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }

    /// Files to import and files to skip, each in the order given, without duplicates.
    public static func split(_ urls: [URL]) -> (supported: [URL], unsupported: [URL]) {
        var seen: Set<String> = []
        var supported: [URL] = [], unsupported: [URL] = []
        for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
            if isSupported(url) { supported.append(url) } else { unsupported.append(url) }
        }
        return (supported, unsupported)
    }

    /// The file name without its extension, e.g. "Weekly sync.mp3" → "Weekly sync".
    /// "Imported audio" when nothing is left.
    public static func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Imported audio" : name
    }

    /// Date of the call: when the file was created, else now.
    public static func date(created: Date?, now: Date = Date()) -> Date {
        created ?? now
    }

    /// Progress line, e.g. "Importing 2 of 5…"; "Importing…" for a single file.
    public static func progress(current: Int, total: Int) -> String {
        total > 1 ? "Importing \(current) of \(total)…" : "Importing…"
    }
}
