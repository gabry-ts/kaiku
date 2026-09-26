import Foundation
import KaikuCore

/// Turns a recording folder into segments.json + transcript.md.
enum TranscriptionJob {
    typealias Progress = @MainActor (String) -> Void

    /// `provider` replaces the one built from Settings (used by the self-test).
    static func run(folder: RecordingFolder, providerKind: ProviderKind, provider: TranscriptionProvider? = nil,
                    progress: @escaping Progress = { _ in }) async throws {
        guard var meta = folder.loadMeta() else {
            throw ProviderError(message: "meta.json missing in \(folder.url.path)")
        }
        meta.status = .transcribing
        meta.error = nil
        try? folder.saveMeta(meta)

        do {
            try await transcribe(folder: folder, meta: &meta, providerKind: providerKind, provider: provider, progress: progress)
        } catch {
            Log.transcription.error("Transcription failed: \(error.diagnosticDescription, privacy: .public)")
            meta.status = .error
            meta.error = error.diagnosticDescription
            try? folder.saveMeta(meta)
            throw error
        }
    }

    private static func transcribe(folder: RecordingFolder, meta: inout RecordingMeta, providerKind: ProviderKind,
                                   provider injected: TranscriptionProvider?, progress: Progress) async throws {
        let fm = FileManager.default
        let hasMic = fm.fileExists(atPath: folder.micURL.path)
        let hasSystem = fm.fileExists(atPath: folder.systemURL.path)
        guard hasMic || hasSystem else { throw ProviderError(message: "No audio files in \(folder.url.path)") }

        await progress("Preparing audio…")
        // Mixed file for listening; not fatal if it fails.
        if hasMic && hasSystem && !fm.fileExists(atPath: folder.mixedURL.path) {
            try? await AudioTools.mix(mic: folder.micURL, system: folder.systemURL, output: folder.mixedURL)
        }

        let provider = try injected ?? ProviderFactory.make(providerKind)
        Log.transcription.info("Transcribing \(folder.url.lastPathComponent, privacy: .public) with \(provider.name, privacy: .public)")
        let language: String? = meta.language == "auto" ? nil : meta.language
        var all: [Segment] = []
        var detected: [String] = []
        var sentSeconds = 0.0
        let trim = AppSettings.shouldTrimSilence(for: providerKind)
        let options = AppSettings.trimOptions
        let workDir = try AudioTools.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let steps = (hasMic ? 1 : 0) + (hasSystem ? 1 : 0)
        func track(_ url: URL, cache: URL, diarize: Bool) async throws -> TrackCache {
            try await transcribeTrack(url, cache: cache, provider: provider, language: language, diarize: diarize,
                                      trim: trim, options: options, dir: workDir)
        }
        if hasMic {
            await progress(steps > 1 ? "Transcribing your microphone (1 of 2)…" : "Transcribing your microphone…")
            let r = try await track(folder.micURL, cache: folder.micPartialURL, diarize: false)
            sentSeconds += r.seconds
            let me = AppSettings.meLabel
            all += r.segments.map { var s = $0; s.speaker = me; return s }
            if let l = r.detectedLanguage { detected.append(l) }
        }
        let systemDuration = await Task.detached { AudioFiles.duration(folder.systemURL) }.value
        if hasSystem, (systemDuration ?? 0) > 0.5 {
            await progress(steps > 1 ? "Transcribing call audio (2 of 2)…" : "Transcribing call audio…")
            let diarize = provider.supportsDiarization
            let r = try await track(folder.systemURL, cache: folder.systemPartialURL, diarize: diarize)
            sentSeconds += r.seconds
            if diarize && r.segments.contains(where: { $0.speaker != nil }) {
                all += TranscriptFormatter.normalizeSpeakers(r.segments)
            } else {
                let others = AppSettings.othersLabel
                all += r.segments.map { var s = $0; s.speaker = others; return s }
            }
            if let l = r.detectedLanguage { detected.append(l) }
        }

        await progress("Writing transcript…")
        let uniqueDetected = detected.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        meta.status = .done
        meta.error = nil
        meta.provider = providerKind.displayName
        meta.model = provider.name
        meta.detectedLanguage = uniqueDetected.isEmpty ? nil : uniqueDetected.joined(separator: ", ")
        let modelID = providerKind == .whisperCpp ? nil : AppSettings.model(for: providerKind)
        meta.modelID = modelID
        meta.transcribedSeconds = sentSeconds
        if let modelID {
            meta.estimatedCostUSD = CostEstimator.pricePerHour(model: modelID, overrides: AppSettings.priceOverrides)
                .map { CostEstimator.estimate(seconds: sentSeconds, pricePerHour: $0) }
        } else {
            meta.estimatedCostUSD = 0
        }

        // Drop the other people's voices picked up by the mic from the speakers.
        if AppSettings.removeEcho, let routes = meta.outputRoutes, routes.contains(where: { !$0.isHeadphones }) {
            all = EchoFilter.markEchoes(all, meLabel: AppSettings.meLabel, routes: routes)
            let n = all.filter { $0.droppedAsEcho == true }.count
            if n > 0 { Log.transcription.info("Hid \(n) echoed microphone segments") }
        }
        // Keep edits made in the library while this job ran.
        if let latest = folder.loadMeta() {
            meta.title = latest.title
            meta.tags = latest.tags
            meta.bookmarks = latest.bookmarks
            meta.speakerNames = latest.speakerNames
        }
        try folder.saveSegments(all)
        try TranscriptWriter.write(folder: folder, meta: meta, rawSegments: all)
        try? folder.saveMeta(meta)
        folder.removePartials()
    }

    /// Transcribes one track. The result is saved to `cache` so that, if a later step fails,
    /// trying again with the same settings reuses it instead of paying for it again.
    private static func transcribeTrack(_ url: URL, cache: URL, provider: TranscriptionProvider, language: String?,
                                        diarize: Bool, trim: Bool, options: SilenceTrimmer.Options, dir: URL) async throws -> TrackCache {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = TrackCache.Key(provider: provider.name, language: language, trim: trim ? options : nil,
                                 audioBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                                 audioModified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        if let saved = TrackCache.reusable(try? Data(contentsOf: cache), for: key) {
            Log.transcription.info("Reusing the saved result for \(url.lastPathComponent, privacy: .public)")
            return saved
        }
        let input = await prepare(url, trim: trim, options: options, dir: dir)
        guard !input.skip else { return TrackCache(key: key, segments: [], detectedLanguage: nil, seconds: 0) }
        let r = try await provider.transcribe(fileURL: input.url, language: language, diarize: diarize)
        let result = TrackCache(key: key, segments: input.remap(r.segments), detectedLanguage: r.detectedLanguage, seconds: input.seconds)
        try? JSONEncoder().encode(result).write(to: cache, options: .atomic)
        return result
    }
}

extension TranscriptionJob {
    /// The file actually sent to the provider, and how to map its times back.
    struct Input {
        let url: URL
        let map: TimeMap?
        let seconds: Double
        /// The track is only silence, so there is nothing to send.
        var skip = false
        func remap(_ segments: [Segment]) -> [Segment] { map?.remap(segments) ?? segments }
    }

    /// With trimming on, cuts long silences into a temporary file for the provider only.
    /// The original audio is never modified. Falls back to the original on any problem
    /// or when there is little to cut.
    static func prepare(_ url: URL, trim: Bool, options: SilenceTrimmer.Options, dir: URL) async -> Input {
        await Task.detached(priority: .userInitiated) { () -> Input in
            let original = AudioFiles.duration(url) ?? 0
            guard trim else { return Input(url: url, map: nil, seconds: original) }
            do {
                let (peaks, duration) = try AudioFiles.peaks(url, window: 0.05)
                let silences = SilenceTrimmer.silences(peaks: peaks, window: 0.05, options: options)
                let map: TimeMap
                switch SilenceTrimmer.plan(duration: duration, silences: silences, padding: options.padding) {
                case .skip:
                    Log.transcription.info("Skipped \(url.lastPathComponent, privacy: .public): only silence")
                    return Input(url: url, map: nil, seconds: 0, skip: true)
                case .original:
                    return Input(url: url, map: nil, seconds: duration)
                case .trimmed(let m):
                    map = m
                }
                let out = dir.appendingPathComponent("trimmed-" + url.deletingPathExtension().lastPathComponent + ".m4a")
                try AudioFiles.writeRanges(url, keep: map.keep, output: out)
                Log.transcription.info("Trimmed \(url.lastPathComponent, privacy: .public): \(Int(duration)) s -> \(Int(map.trimmedDuration)) s")
                return Input(url: out, map: map, seconds: map.trimmedDuration)
            } catch {
                Log.transcription.error("Silence trimming skipped: \(error.diagnosticDescription, privacy: .public)")
                return Input(url: url, map: nil, seconds: original)
            }
        }.value
    }
}

/// Builds transcript.md from raw segments, applying the speaker name mapping.
/// Used after transcription and whenever speakers are renamed.
enum TranscriptWriter {
    static func languageLabel(_ meta: RecordingMeta) -> String {
        guard meta.language == "auto" else { return meta.language }
        return meta.detectedLanguage.map { "auto (detected: \($0))" } ?? "auto"
    }

    /// Segments with display names applied, merged by speaker turn unless `merge` is false.
    static func displaySegments(meta: RecordingMeta, rawSegments: [Segment], merge: Bool = true) -> [Segment] {
        let names = meta.speakerNames ?? [:]
        let renamed = rawSegments.filter { $0.droppedAsEcho != true }.map { s -> Segment in
            var c = s
            if let raw = s.speaker, let name = names[raw], !name.isEmpty { c.speaker = name }
            return c
        }
        return merge ? TranscriptFormatter.merge(renamed) : renamed
    }

    @discardableResult
    static func write(folder: RecordingFolder, meta: RecordingMeta, rawSegments: [Segment]) throws -> String {
        let header = TranscriptFormatter.Header(
            title: meta.title, date: meta.date, durationSeconds: meta.durationSeconds,
            provider: meta.model ?? meta.provider ?? "unknown", language: languageLabel(meta),
            audioFiles: folder.audioURLs.map(\.lastPathComponent), tags: meta.tags ?? [])
        let markdown = TranscriptFormatter.markdown(header: header, merged: displaySegments(meta: meta, rawSegments: rawSegments),
                                                    bookmarks: meta.bookmarks ?? [])
        try markdown.write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
        return markdown
    }

    /// Distinct raw speaker labels in order of first appearance.
    static func speakers(in rawSegments: [Segment]) -> [String] {
        var seen: [String] = []
        for s in rawSegments.sorted(by: { $0.start < $1.start }) where s.droppedAsEcho != true {
            if let sp = s.speaker, !seen.contains(sp) { seen.append(sp) }
        }
        return seen
    }
}
