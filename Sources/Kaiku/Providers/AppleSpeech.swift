import AVFoundation
import CoreMedia
import KaikuCore
import Speech

/// Languages and models of the speech recognizer built into macOS 26.
@available(macOS 26, *)
enum AppleSpeech {
    /// The recognizer's locale for a language setting: "auto" is the system language.
    /// Nil when the recognizer doesn't know the language.
    static func locale(for language: String) async -> Locale? {
        let wanted = language == "auto" ? Locale.current : Locale(identifier: language)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) { return match }
        // A bare code like "en": take the variant of this Mac's region, else the most common one.
        guard let code = wanted.language.languageCode?.identifier else { return nil }
        let variants = await SpeechTranscriber.supportedLocales.filter { $0.language.languageCode?.identifier == code }
        let likelyRegion = Locale.Language(identifier: code).maximalIdentifier.split(separator: "-").last.map(String.init)
        return variants.first { $0.region == Locale.current.region }
            ?? variants.first { $0.region?.identifier == likelyRegion }
            ?? variants.first
    }

    /// Volatile results give the text as it is spoken; final ones replace them.
    static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// For a recorded file: final results only, with the time of every word.
    static func fileTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// A result as plain values, its text split where the recognizer timed it.
    static func recognized(_ result: SpeechTranscriber.Result) -> RecognizedSpeech {
        let text = result.text
        let runs = text.runs.map { run -> RecognizedSpeech.Run in
            let range = run.audioTimeRange
            return RecognizedSpeech.Run(String(text[run.range].characters), start: range?.start.seconds, end: range?.end.seconds)
        }
        return RecognizedSpeech(start: result.range.start.seconds, end: result.range.end.seconds, runs: runs)
    }

    /// e.g. "Italian (Italy)".
    static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    static func name(ofLanguage language: String) -> String {
        language == "auto" ? "the system language" : (Locale.current.localizedString(forLanguageCode: language) ?? language)
    }

    /// True when the model is on this Mac. After a catalog update the system reports an older
    /// model on disk as only supported, though the recognizer still runs with it.
    static func isInstalled(_ locale: Locale) async -> Bool {
        if await AssetInventory.status(forModules: [transcriber(locale)]) == .installed { return true }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Only asks the system what is installed; nothing is downloaded.
    static func readiness(language: String) async -> LiveReadiness {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("The system speech recognizer isn't available on this Mac.")
        }
        guard let locale = await locale(for: language) else {
            return .unavailable("The system speech recognizer doesn't support \(name(ofLanguage: language)).")
        }
        if await isInstalled(locale) { return .ready }
        switch await AssetInventory.status(forModules: [transcriber(locale)]) {
        case .installed: return .ready
        case .downloading: return .downloading(0)
        case .supported: return .needsDownload("The speech model for \(name(locale)) isn't on this Mac yet.")
        case .unsupported: return .unavailable("The system speech recognizer doesn't support \(name(locale)).")
        @unknown default: return .unavailable("The system speech recognizer isn't available.")
        }
    }

    /// Downloads and installs the model of the language, reporting progress 0...1.
    static func download(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let locale = await locale(for: language) else {
            throw LiveEngineError("The system speech recognizer doesn't support \(name(ofLanguage: language)).")
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(locale)]) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            progress(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }
}

/// Converts recorded audio to the format the speech recognizer takes.
final class SpeechAudioConverter {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw LiveEngineError("could not convert \(buffer.format) to \(format)")
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }
}
