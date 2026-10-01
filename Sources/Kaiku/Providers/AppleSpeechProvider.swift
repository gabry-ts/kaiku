import AVFoundation
import CoreMedia
import KaikuCore
import os
import Speech

/// Transcription with the speech recognizer built into macOS 26, on this Mac.
@available(macOS 26, *)
struct AppleSpeechProvider: TranscriptionProvider {
    var name: String { "Apple speech recognizer" }
    var supportsDiarization: Bool { false }

    /// The recognizer can't detect the language: nil is the system language.
    func transcribe(fileURL: URL, language: String?, diarize: Bool) async throws -> TranscriptionResult {
        let language = language ?? "auto"
        guard SpeechTranscriber.isAvailable else {
            throw ProviderError(message: "The system speech recognizer isn't available on this Mac.")
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
