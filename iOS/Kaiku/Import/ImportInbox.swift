import Foundation

/// Files other parts of the system hand over through the App Group, imported when the app opens.
enum ImportInbox {
    /// Imports whatever is waiting in the inbox. Each file is removed from it once handled.
    @MainActor
    static func drain() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: AppGroup.imports, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard !items.isEmpty else { return }
        PhoneImporter.shared.importFiles(items.sorted { $0.lastPathComponent < $1.lastPathComponent }, consume: true)
    }
}
