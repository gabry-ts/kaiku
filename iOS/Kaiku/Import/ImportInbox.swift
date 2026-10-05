import CoreFoundation
import Foundation
import KaikuCore

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
        if !files.isEmpty { PhoneImporter.shared.importFiles(files, consume: true) }
        drainBroadcasts()
    }

    // MARK: Broadcasts

    /// Broadcasts that are not finished after this long were cut off (the extension was killed) and are imported as they are.
    private static let staleAfter: TimeInterval = 6 * 3600
    @MainActor private static var handling = Set<URL>()

    /// Wakes the app's import when the broadcast extension starts or finishes.
    static func observeBroadcasts() {
        let callback: CFNotificationCallback = { _, _, _, _, _ in
            Task { @MainActor in ImportInbox.drainBroadcasts() }
        }
        for name in [AppGroup.Notification.broadcastStarted, AppGroup.Notification.broadcastFinished] {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, callback,
                                            name as CFString, nil, .deliverImmediately)
        }
    }

    /// Imports the finished broadcasts (and the old unfinished ones) as calls of the iPhone call source.
    @MainActor
    static func drainBroadcasts() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: AppGroup.broadcasts, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where !handling.contains(dir) {
            let started = timestamp(dir, "started.json", key: "date")
            let ended = timestamp(dir, "done.json", key: "endDate")
            guard let started else {
                // No start record: a leftover of a broadcast that never began.
                if ended != nil || ((try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true) { try? fm.removeItem(at: dir) }
                continue
            }
            guard ended != nil || Date().timeIntervalSince(started) > staleAfter else { continue }
            handling.insert(dir)
            Task {
                await importBroadcast(dir, started: started, ended: ended)
                handling.remove(dir)
            }
        }
    }

    /// Converts mic.caf and system.caf to m4a in a new call folder, then removes the broadcast folder.
    @MainActor
    private static func importBroadcast(_ dir: URL, started: Date, ended: Date?) async {
        let fm = FileManager.default
        do {
            let work = try AudioTools.makeTempDir()
            defer { try? fm.removeItem(at: work) }
            let tracks = await Task.detached { convert(dir, into: work) }.value
            guard let seconds = tracks.max() else { throw ImportError(message: "The broadcast has no audio.") }

            let title = Naming.defaultTitle(date: started)
            let folder = try RecordingFolder.create(base: PhoneSettings.baseFolder, date: started, title: title)
            do {
                for name in [RecordingFolder.micName, RecordingFolder.systemName]
                where fm.fileExists(atPath: work.appendingPathComponent(name).path) {
                    try fm.moveItem(at: work.appendingPathComponent(name), to: folder.url.appendingPathComponent(name))
                }
            } catch {
                // Only the empty folder just made is removed.
                try? fm.removeItem(at: folder.url)
                throw error
            }
            try folder.saveMeta(RecordingMeta(
                title: title, date: started, durationSeconds: seconds, language: PhoneSettings.language,
                status: .recovered, source: "iPhone call"))
            try? fm.removeItem(at: dir)
            PhoneJobs.shared.enqueue(folder)
            PhoneJobs.shared.onChange?()
        } catch {
            PhoneImporter.shared.problems.append("Broadcast: \(error.localizedDescription)")
            try? fm.removeItem(at: dir)
        }
    }

    /// Blocking. Returns the duration of each track that was converted.
    nonisolated private static func convert(_ dir: URL, into work: URL) -> [Double] {
        [("mic", RecordingFolder.micName), ("system", RecordingFolder.systemName)].compactMap { raw, name in
            let source = dir.appendingPathComponent("\(raw).caf")
            guard FileManager.default.fileExists(atPath: source.path), (AudioFiles.duration(source) ?? 0) > 0 else { return nil }
            return try? AudioFiles.convertToM4A(source, output: work.appendingPathComponent(name))
        }
    }

    private static func timestamp(_ dir: URL, _ file: String, key: String) -> Date? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
              let values = try? JSONDecoder().decode([String: Double].self, from: data),
              let time = values[key] else { return nil }
        return Date(timeIntervalSince1970: time)
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
