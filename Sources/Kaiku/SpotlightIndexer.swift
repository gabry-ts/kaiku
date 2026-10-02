import Combine
import CoreSpotlight
import Foundation
import KaikuCore
import UniformTypeIdentifiers

/// Keeps the calls searchable from Spotlight, and finds the call of a result that was opened.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    /// Every call item lives in this domain, so they can be removed together.
    nonisolated static let domain = "com.gabrielepartiti.kaiku.calls"

    /// What was indexed last for each call (by folder key), so only changed calls are sent again.
    private var signatures: [String: String]?
    private var running = false
    private var again = false
    private var observer: AnyCancellable?

    /// Indexes the library now and again whenever it changes.
    func start() {
        observer = AppState.shared.$libraryVersion
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
        update()
    }

    /// The call a Spotlight result stands for, nil when it is gone.
    nonisolated static func folder(for activity: NSUserActivity) -> RecordingFolder? {
        guard activity.activityType == CSSearchableItemActionType,
              let key = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        let folder = RecordingFolder(url: URL(fileURLWithPath: key, isDirectory: true))
        return FileManager.default.fileExists(atPath: folder.metaURL.path) ? folder : nil
    }

    private func update() {
        guard !running else { again = true; return }
        running = true
        let base = AppSettings.baseFolder
        let known = signatures
        Task {
            let result = await Task.detached(priority: .utility) { Self.sync(base: base, known: known) }.value
            signatures = result
            running = false
            if again {
                again = false
                update()
            }
        }
    }

    /// Sends new and changed calls to the index and removes the ones that are gone.
    /// The first run starts from an empty index, which also drops stale items.
    nonisolated private static func sync(base: URL, known: [String: String]?) -> [String: String] {
        let index = CSSearchableIndex.default()
        if known == nil {
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
        }
        var signatures: [String: String] = [:]
        var items: [CSSearchableItem] = []
        for call in CallLibrary(base: base).calls() {
            let key = call.folder.key
            let signature = signature(of: call.folder)
            signatures[key] = signature
            if known?[key] == signature { continue }
            items.append(item(for: call))
        }
        let gone = (known ?? [:]).keys.filter { signatures[$0] == nil }
        if !gone.isEmpty { index.deleteSearchableItems(withIdentifiers: Array(gone)) { _ in } }
        if !items.isEmpty {
            index.indexSearchableItems(items) { error in
                if let error { Log.app.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        return signatures
    }

    /// Changes whenever the call's meta.json, transcript or summary is written.
    nonisolated private static func signature(of folder: RecordingFolder) -> String {
        [folder.metaURL, folder.transcriptURL, folder.summaryURL].map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return String(date?.timeIntervalSince1970 ?? 0)
        }.joined(separator: "|")
    }

    nonisolated private static func item(for call: CallEntry) -> CSSearchableItem {
        let meta = call.meta
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = meta.title
        attributes.displayName = meta.title
        attributes.contentCreationDate = meta.date
        attributes.contentModificationDate = meta.date
        attributes.keywords = (meta.tags ?? []) + [meta.source, meta.sourceApp].compactMap { $0 }
        let transcript = (try? String(contentsOf: call.folder.transcriptURL, encoding: .utf8))
            .map { SpotlightText.snippet(fromTranscript: $0) } ?? ""
        attributes.textContent = transcript
        attributes.contentDescription = [meta.source ?? meta.sourceApp, String(transcript.prefix(160))]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let item = CSSearchableItem(uniqueIdentifier: call.folder.key, domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }
}
