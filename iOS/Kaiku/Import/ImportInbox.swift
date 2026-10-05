import Foundation

/// Files other parts of the system hand over through the App Group, imported when the app opens.
/// The share extension writes Imports/<id>/<file> next to a meta.json holding the file's `createdAt`.
enum ImportInbox {
    private static let metaName = "meta.json"

    /// Imports whatever is waiting in the inbox. Each file is removed from it once handled.
    @MainActor
    static func drain() {
        let fm = FileManager.default
        var files: [URL] = []
        let entries = (try? fm.contentsOfDirectory(at: AppGroup.imports, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                files.append(entry)
                continue
            }
            let inner = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            let media = inner.filter { $0.lastPathComponent != metaName }
            if media.isEmpty {
                try? fm.removeItem(at: entry)
                continue
            }
            let created = createdAt(entry.appendingPathComponent(metaName))
            for file in media {
                if let created { try? fm.setAttributes([.creationDate: created], ofItemAtPath: file.path) }
                files.append(file)
            }
        }
        guard !files.isEmpty else { return }
        PhoneImporter.shared.importFiles(files, consume: true)
    }

    /// Removes a handled inbox file, and its folder once only the meta file is left.
    static func remove(_ file: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        guard folder.standardizedFileURL != AppGroup.imports.standardizedFileURL else { return }
        let left = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        if left.allSatisfy({ $0 == metaName }) { try? fm.removeItem(at: folder) }
    }

    private static func createdAt(_ url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode([String: Double].self, from: data),
              let time = meta["createdAt"] else { return nil }
        return Date(timeIntervalSince1970: time)
    }
}
