import Foundation
import KaikuCore

/// Turns a recording folder into segments.json + transcript.md.
enum TranscriptionJob {
    typealias Progress = @MainActor (String) -> Void
    typealias Input = TranscriptionRun.Input

    /// Saved as the error of a call whose transcription was cancelled.
    static let cancelledMessage = TranscriptionRun.cancelledMessage

    /// `provider` replaces the one built from Settings (used by the self-test).
    static func run(folder: RecordingFolder, providerKind: ProviderKind, provider: TranscriptionProvider? = nil,
                    progress: @escaping Progress = { _ in }) async throws {
        let config = TranscriptionRun.Config(
            providerDisplayName: providerKind.displayName,
            modelID: providerKind.isCloud ? AppSettings.model(for: providerKind) : nil,
            trim: AppSettings.shouldTrimSilence(for: providerKind),
            trimOptions: AppSettings.trimOptions,
            meLabel: AppSettings.meLabel,
            othersLabel: AppSettings.othersLabel,
            removeEcho: AppSettings.removeEcho,
            priceOverrides: AppSettings.priceOverrides)
        try await TranscriptionRun.run(folder: folder, config: config,
                                       makeProvider: { try provider ?? ProviderFactory.make(providerKind) }, progress: progress)
    }

    static func prepare(_ url: URL, trim: Bool, options: SilenceTrimmer.Options, dir: URL) async -> Input {
        await TranscriptionRun.prepare(url, trim: trim, options: options, dir: dir)
    }
}

extension TranscriptionJob {
    /// Saves the text heard live as the call's transcript, in place of a provider run.
    /// The call can still be transcribed again from the library.
    static func saveLive(_ transcript: LiveTranscript, folder: RecordingFolder, engine: LiveEngineKind) async throws {
        // Same speaker names as a provider run, so colors and webhooks see one set of names.
        var all = transcript.segments(me: AppSettings.meLabel, them: AppSettings.othersLabel)
        guard !all.isEmpty else { throw ProviderError(message: "The live transcript is empty") }
        // Mixed file for listening; not fatal if it fails.
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.micURL.path), fm.fileExists(atPath: folder.systemURL.path),
           !fm.fileExists(atPath: folder.mixedURL.path) {
            try? await AudioTools.mix(mic: folder.micURL, system: folder.systemURL, output: folder.mixedURL)
        }
        guard var meta = folder.loadMeta() else {
            throw ProviderError(message: "meta.json missing in \(folder.url.path)")
        }
        // Drop the other people's voices picked up by the mic from the speakers.
        if AppSettings.removeEcho, let routes = meta.outputRoutes, routes.contains(where: { !$0.isHeadphones }) {
            all = EchoFilter.markEchoes(all, meLabel: AppSettings.meLabel, routes: routes)
        }
        meta.status = .done
        meta.error = nil
        meta.provider = "Live transcription"
        meta.model = "Live: \(engine.displayName)"
        meta.detectedLanguage = nil
        meta.modelID = nil
        meta.transcribedSeconds = nil
        meta.estimatedCostUSD = 0
        TranscriptionRun.autoNameSpeaker(&meta, segments: all, meLabel: AppSettings.meLabel)
        try folder.saveSegments(all)
        try TranscriptWriter.write(folder: folder, meta: meta, rawSegments: all)
        try folder.saveMeta(meta)
        folder.removePartials()
        Log.transcription.info("Saved the live transcript of \(folder.url.lastPathComponent, privacy: .public): \(all.count) lines")
    }
}
