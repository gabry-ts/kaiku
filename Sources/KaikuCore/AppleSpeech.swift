import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

/// Languages and models of the speech recognizer built into macOS 26.
@available(macOS 26, iOS 26, *)
public enum AppleSpeech {
    /// What the text calls the device the recognizer runs on.
    public static var deviceName: String {
        #if os(iOS)
        return "iPhone"
        #else
        return "Mac"
        #endif
    }

    /// The recognizer's locale for a language setting: "auto" is the system language.
    /// Nil when the recognizer doesn't know the language.
    public static func locale(for language: String) async -> Locale? {
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
    public static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// For a recorded file: final results only, with the time of every word.
    public static func fileTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// A result as plain values, its text split where the recognizer timed it.
    public static func recognized(_ result: SpeechTranscriber.Result) -> RecognizedSpeech {
        let text = result.text
        let runs = text.runs.map { run -> RecognizedSpeech.Run in
            let range = run.audioTimeRange
            return RecognizedSpeech.Run(String(text[run.range].characters), start: range?.start.seconds, end: range?.end.seconds)
        }
        return RecognizedSpeech(start: result.range.start.seconds, end: result.range.end.seconds, runs: runs)
    }

    /// e.g. "Italian (Italy)".
    public static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    public static func name(ofLanguage language: String) -> String {
        language == "auto" ? "the system language" : (Locale.current.localizedString(forLanguageCode: language) ?? language)
    }

    /// True when the model is on this Mac. After a catalog update the system reports an older
    /// model on disk as only supported, though the recognizer still runs with it.
    public static func isInstalled(_ locale: Locale) async -> Bool {
        if await AssetInventory.status(forModules: [transcriber(locale)]) == .installed { return true }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Only asks the system what is installed; nothing is downloaded.
    public static func readiness(language: String) async -> LiveReadiness {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("The system speech recognizer isn't available on this \(deviceName).")
        }
        guard let locale = await locale(for: language) else {
            return .unavailable("The system speech recognizer doesn't support \(name(ofLanguage: language)).")
        }
        if await isInstalled(locale) { return .ready }
        switch await AssetInventory.status(forModules: [transcriber(locale)]) {
        case .installed: return .ready
        case .downloading: return .downloading(0)
        case .supported: return .needsDownload("The speech model for \(name(locale)) isn't on this \(deviceName) yet.")
        case .unsupported: return .unavailable("The system speech recognizer doesn't support \(name(locale)).")
        @unknown default: return .unavailable("The system speech recognizer isn't available.")
        }
    }

    /// Downloads and installs the model of the language, reporting progress 0...1.
    public static func download(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {
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
public final class SpeechAudioConverter {
    public let format: AVAudioFormat
    private var converter: AVAudioConverter?

    public init(to format: AVAudioFormat) {
        self.format = format
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
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

public struct LiveEngineError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Whether an engine can run for a language, shown in Settings.
public enum LiveReadiness: Equatable {
    case ready
    /// A model has to be downloaded first; the text says which.
    case needsDownload(String)
    /// Downloading the model, 0...1.
    case downloading(Double)
    /// The engine can't be used, with the reason.
    case unavailable(String)
}

/// Transcription with the speech recognizer built into macOS 26, on this Mac.
@available(macOS 26, iOS 26, *)
public struct AppleSpeechProvider: TranscriptionProvider {
    public init() {}

    public var name: String { "Apple speech recognizer" }
    public var supportsDiarization: Bool { false }

    /// The recognizer can't detect the language: nil is the system language.
    public func transcribe(fileURL: URL, language: String?, diarize: Bool) async throws -> TranscriptionResult {
        let language = language ?? "auto"
        guard SpeechTranscriber.isAvailable else {
            throw ProviderError(message: "The system speech recognizer isn't available on this \(AppleSpeech.deviceName).")
        }
        guard let locale = await AppleSpeech.locale(for: language) else {
            throw ProviderError(message: "The system speech recognizer doesn't support \(AppleSpeech.name(ofLanguage: language)).")
        }
        // Never download during a transcription: that is done from Settings.
        guard await AppleSpeech.isInstalled(locale) else {
            throw ProviderError(message: "The speech model for \(AppleSpeech.name(locale)) isn't downloaded. Get it in Settings > Transcription.")
        }

        let transcriber = AppleSpeech.fileTranscriber(locale)
        let file = try AVAudioFile(forReading: fileURL)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                         considering: file.processingFormat) else {
            throw ProviderError(message: "No audio format the speech recognizer accepts.")
        }
        Log.transcription.info("Recognizing \(fileURL.lastPathComponent, privacy: .public) in \(locale.identifier, privacy: .public)")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task { () throws -> [RecognizedSpeech] in
            var all: [RecognizedSpeech] = []
            for try await result in transcriber.results where result.isFinal {
                all.append(AppleSpeech.recognized(result))
            }
            return all
        }
        let reader = Reader(file: file, converter: SpeechAudioConverter(to: format))
        do {
            // The analyzer asks for the next piece of the file when it is ready for it.
            let input = AsyncStream<AnalyzerInput>(unfolding: { reader.next() })
            if let last = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            if let error = reader.error { throw error }
            return TranscriptionResult(segments: SpeechSegments.segments(from: try await results.value))
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Reads the file a second at a time, in the recognizer's format.
    private final class Reader: @unchecked Sendable {
        private struct State {
            let file: AVAudioFile
            let converter: SpeechAudioConverter
            var error: Error?
        }

        private let state: OSAllocatedUnfairLock<State>

        init(file: AVAudioFile, converter: SpeechAudioConverter) {
            state = OSAllocatedUnfairLock(uncheckedState: State(file: file, converter: converter))
        }

        /// What stopped the reading before the end of the file, if anything.
        var error: Error? { state.withLockUnchecked { $0.error } }

        /// The next piece of audio, nil at the end of the file or after an error.
        func next() -> AnalyzerInput? {
            state.withLockUnchecked { s -> AnalyzerInput? in
                let format = s.file.processingFormat
                while s.error == nil, s.file.framePosition < s.file.length {
                    do {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
                            throw ProviderError(message: "Could not read \(s.file.url.lastPathComponent).")
                        }
                        try s.file.read(into: buffer)
                        guard buffer.frameLength > 0 else { return nil }
                        let converted = try s.converter.convert(buffer)
                        if converted.frameLength > 0 { return AnalyzerInput(buffer: converted) }
                    } catch {
                        s.error = error
                    }
                }
                return nil
            }
        }
    }
}
