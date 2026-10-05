import Foundation
import KaikuCore
import Observation

/// The calls in Documents/Kaiku, read from disk.
@MainActor
@Observable
final class LibraryStore {
    private(set) var calls: [CallEntry] = []

    var base: URL { PhoneSettings.baseFolder }

    func reload() {
        let library = CallLibrary(base: base)
        Task {
            let loaded = await Task.detached { library.calls() }.value
            calls = loaded
        }
    }

    /// Calls whose title, tags or source contain the text, or whose transcript does.
    func calls(matching query: String) -> [CallEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return calls }
        let filter = CallFilter(query: text)
        return calls.filter { entry in
            if filter.matches(entry.meta) { return true }
            guard let transcript = try? String(contentsOf: entry.folder.transcriptURL, encoding: .utf8) else { return false }
            return transcript.range(of: text, options: TranscriptSearch.options) != nil
        }
    }

    func rename(_ folder: RecordingFolder, to title: String) {
        _ = try? folder.rename(to: title)
        reload()
    }

    func setTags(_ folder: RecordingFolder, _ tags: [String]) {
        folder.setTags(tags)
        reload()
    }

    func delete(_ folder: RecordingFolder) {
        try? FileManager.default.removeItem(at: folder.url)
        reload()
    }
}
