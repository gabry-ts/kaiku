import Foundation

/// The container shared between the app and its extensions.
enum AppGroup {
    static let id = "group.com.gabrielepartiti.kaiku.ios"

    /// Falls back to the app's own Documents folder when the group isn't available (e.g. unsigned builds).
    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Audio files handed over by the share extension, waiting to be imported.
    static var imports: URL { directory("Imports") }
    /// Screen recordings written by the broadcast extension.
    static var broadcasts: URL { directory("Broadcasts") }

    /// Shared flag read by the Control Center toggle.
    static let isRecordingKey = "isRecording"

    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    /// Darwin notification names, for waking the app from an extension.
    enum Notification {
        static let importReady = "\(id).import-ready"
        static let broadcastStopped = "\(id).broadcast-stopped"
    }

    private static func directory(_ name: String) -> URL {
        let url = container.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
