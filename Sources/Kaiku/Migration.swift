import Foundation
import KaikuCore

/// One-time migration of settings, API keys, recordings and models from the app's
/// previous name (mc.Rofone). Runs at launch before anything reads the settings;
/// safe when there is nothing to migrate and never runs twice.
enum Migration {
    static let legacyDomain = "com.gabrielepartiti.mcrofone"
    static let legacyName = "mc.Rofone"
    static let doneKey = "legacyMigrationDone"

    struct Context {
        var home: URL
        var legacyDomain: String
        /// The defaults to migrate into and their domain name.
        var target: UserDefaults
        var targetDomain: String
        /// Copies Keychain items from the legacy service, returns how many.
        var copyKeychain: () -> Int
        var log: (String) -> Void
    }

    static func runAtLaunch() {
        let domain = Bundle.main.bundleIdentifier ?? "com.gabrielepartiti.kaiku"
        run(Context(home: FileManager.default.homeDirectoryForCurrentUser,
                    legacyDomain: legacyDomain,
                    target: .standard,
                    targetDomain: domain,
                    copyKeychain: { Keychain.copyItems(from: Keychain.legacyService) },
                    log: { Log.app.info("Migration: \($0, privacy: .public)") }))
    }

    static func run(_ c: Context) {
        guard !c.target.bool(forKey: doneKey) else { return }
        let fm = FileManager.default
        let home = c.home.path

        // 1. Settings (including the saved microphone state for crash restore).
        let old = c.target.persistentDomain(forName: c.legacyDomain) ?? [:]
        let existing = c.target.persistentDomain(forName: c.targetDomain) ?? [:]
        var copied = 0
        for (key, value) in old where existing[key] == nil {
            c.target.set(value, forKey: key)
            copied += 1
        }
        c.log(old.isEmpty ? "no settings from \(c.legacyDomain)" : "copied \(copied) of \(old.count) settings")

        // 2. API keys and webhook header values.
        c.log("copied \(c.copyKeychain()) Keychain items")

        var moves: [PathMove] = []

        // 3. Recordings, only when the base folder is the old default.
        let oldDocs = c.home.appendingPathComponent("Documents/\(legacyName)", isDirectory: true)
        let newDocs = c.home.appendingPathComponent("Documents/Kaiku", isDirectory: true)
        let base = c.target.string(forKey: Keys.baseFolder) ?? ""
        if base.isEmpty || LegacyMigration.isSame(base, as: oldDocs.path, home: home) {
            switch LegacyMigration.folderAction(oldExists: fm.fileExists(atPath: oldDocs.path),
                                                newExists: fm.fileExists(atPath: newDocs.path)) {
            case .move:
                if move(oldDocs, to: newDocs, c) {
                    moves.append(PathMove(from: oldDocs.path, to: newDocs.path))
                    c.target.set(newDocs.path, forKey: Keys.baseFolder)
                } else {
                    c.target.set(oldDocs.path, forKey: Keys.baseFolder)
                }
            case .keepOld:
                c.target.set(oldDocs.path, forKey: Keys.baseFolder)
                c.log("both \(oldDocs.path) and \(newDocs.path) exist; keeping recordings in the old folder")
            case .none:
                break
            }
        } else {
            c.log("custom recordings folder, left as is")
        }

        // 4. whisper.cpp models.
        let oldSupport = c.home.appendingPathComponent("Library/Application Support/\(legacyName)", isDirectory: true)
        let newSupport = c.home.appendingPathComponent("Library/Application Support/Kaiku", isDirectory: true)
        switch LegacyMigration.folderAction(oldExists: fm.fileExists(atPath: oldSupport.path),
                                            newExists: fm.fileExists(atPath: newSupport.path)) {
        case .move:
            if move(oldSupport, to: newSupport, c) {
                moves.append(PathMove(from: oldSupport.path, to: newSupport.path))
            } else {
                keepOldModel(oldSupport, c)
            }
        case .keepOld:
            keepOldModel(oldSupport, c)
            c.log("both \(oldSupport.path) and \(newSupport.path) exist; models left in place")
        case .none:
            break
        }

        // 5. Stored paths that pointed into the moved folders.
        if !moves.isEmpty {
            let current = c.target.persistentDomain(forName: c.targetDomain) ?? [:]
            let rewritten = LegacyMigration.rewrittenValues(current, moves: moves, home: home)
            for (key, value) in rewritten { c.target.set(value, forKey: key) }
            c.log("rewrote \(rewritten.count) stored paths")
        }

        c.target.set(true, forKey: doneKey)
    }

    private static func move(_ from: URL, to: URL, _ c: Context) -> Bool {
        do {
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: from, to: to)
            c.log("moved \(from.path) to \(to.path)")
            return true
        } catch {
            c.log("could not move \(from.path) to \(to.path): \(error.localizedDescription); keeping the old folder")
            return false
        }
    }

    /// The default model path points to the new folder: keep the old model if the
    /// user never picked one explicitly.
    private static func keepOldModel(_ oldSupport: URL, _ c: Context) {
        guard (c.target.string(forKey: Keys.whisperModel) ?? "").isEmpty else { return }
        c.target.set(oldSupport.appendingPathComponent("models/ggml-large-v3-turbo.bin").path, forKey: Keys.whisperModel)
    }
}
