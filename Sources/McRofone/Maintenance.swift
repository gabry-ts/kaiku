import Foundation
import McRofoneCore

/// Turns the crash-safe CAF files of a recording into the final .m4a files.
enum AudioFinalizer {
    /// Converts mic.caf / system.caf to .m4a. Each CAF is removed only after its .m4a
    /// has been written and checked. Returns the longest track duration, or nil when
    /// there was nothing to convert. Blocking: call off the main thread.
    static func finalize(_ folder: RecordingFolder) throws -> Double? {
        let fm = FileManager.default
        var longest: Double?
        var errors: [String] = []
        for (raw, final) in [(folder.micRawURL, folder.micURL), (folder.systemRawURL, folder.systemURL)] {
            guard fm.fileExists(atPath: raw.path) else { continue }
            if (AudioFiles.duration(raw) ?? 0) <= 0 {
                // Track opened but never received audio: nothing to keep.
                try? fm.removeItem(at: raw)
                continue
            }
            do {
                let d = try AudioFiles.convertToM4A(raw, output: final)
                try fm.removeItem(at: raw)
                longest = max(longest ?? 0, d)
            } catch {
                errors.append("\(raw.lastPathComponent): \(error.diagnosticDescription)")
            }
        }
        if !errors.isEmpty {
            throw AudioCaptureError("Could not save the audio. The raw recording is kept in the call folder.\n" + errors.joined(separator: "\n"))
        }
        return longest
    }
}

/// Recovers calls left in "recording" or "paused" state by a crash or a quit.
enum Recovery {
    struct Outcome {
        let folder: RecordingFolder
        let title: String
        let recovered: Bool
    }

    static func needsRecovery(_ meta: RecordingMeta) -> Bool {
        meta.status == .recording || meta.status == .paused
    }

    /// Blocking: call off the main thread. `skip` is the folder being recorded right now, if any.
    static func recoverAll(base: URL, skip: String?) -> [Outcome] {
        var outcomes: [Outcome] = []
        for folder in RecordingFolder.scan(base: base) where folder.key != skip {
            guard var meta = folder.loadMeta(), needsRecovery(meta) else { continue }
            let hadRaw = FileManager.default.fileExists(atPath: folder.micRawURL.path)
                || FileManager.default.fileExists(atPath: folder.systemRawURL.path)
            // Close a pause left open: nothing was recorded after it anyway.
            if var pauses = meta.pauses, let last = pauses.last, last.end == nil {
                pauses[pauses.count - 1].end = last.start
                meta.pauses = pauses
            }
            var recovered = false
            do {
                if let duration = try AudioFinalizer.finalize(folder) {
                    meta.durationSeconds = duration
                    meta.status = .recovered
                    meta.error = nil
                    recovered = true
                } else if !folder.audioURLs.isEmpty {
                    meta.status = .error
                    meta.error = "Recording interrupted when the app quit. Use Re-transcribe."
                } else {
                    meta.status = .error
                    meta.error = hadRaw ? "The recording was interrupted before any audio was saved." : "The recording was interrupted and no audio was found."
                }
            } catch {
                meta.status = .error
                meta.error = error.diagnosticDescription
            }
            try? folder.saveMeta(meta)
            Log.app.info("Recovery of \(folder.url.lastPathComponent, privacy: .public): \(meta.status.rawValue, privacy: .public)")
            outcomes.append(Outcome(folder: folder, title: meta.title, recovered: recovered))
        }
        return outcomes
    }
}

/// Disk usage and the "delete old audio" cleanup.
enum Storage {
    static func candidates(base: URL) -> [StorageCleanup.Candidate] {
        RecordingFolder.scan(base: base).compactMap { f in
            guard let m = f.loadMeta() else { return nil }
            return StorageCleanup.Candidate(id: f.key, date: m.date, audioBytes: f.audioBytes,
                                            hasTranscript: f.hasTranscript, audioDeleted: m.audioDeleted == true)
        }
    }

    static func totalBytes(base: URL) -> (total: Int64, audio: Int64, calls: Int) {
        let folders = RecordingFolder.scan(base: base)
        return (folders.reduce(0) { $0 + $1.totalBytes }, folders.reduce(0) { $0 + $1.audioBytes }, folders.count)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
