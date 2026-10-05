import AVFoundation
import KaikuCore
import UIKit
import os
import whisper

/// On-device transcription with whisper.cpp linked as a library, on the GPU while the app is open.
struct WhisperLibProvider: TranscriptionProvider {
    let modelURL: URL

    var name: String { "whisper.cpp (\(modelURL.lastPathComponent))" }
    var supportsDiarization: Bool { false }

    /// Seconds of audio decoded at a time.
    private static let windowSeconds = 600.0
    private static let log = Logger(subsystem: "com.gabrielepartiti.kaiku.ios", category: "whisper")

    func transcribe(fileURL: URL, language: String?, diarize: Bool) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ProviderError(message: "The whisper model isn't downloaded. Get one in Settings > Transcription > Whisper models.")
        }
        let flag = CancelFlag()
        let modelPath = modelURL.path
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try await Self.run(fileURL: fileURL, modelPath: modelPath, language: language, flag: flag)
            }.value
        } onCancel: {
            flag.cancel()
        }
    }

    private static func run(fileURL: URL, modelPath: String, language: String?, flag: CancelFlag) async throws -> TranscriptionResult {
        let reader = try PCMReader(url: fileURL, sampleRate: AudioTools.speechRate, channels: 1)
        let windowSamples = Int(windowSeconds * AudioTools.speechRate)
        var engine = WhisperEngine?.none
        var segments: [Segment] = []
        var detected: String?
        var offset = 0.0
        var samples: [Float] = []
        samples.reserveCapacity(windowSamples)

        func flush() async throws {
            guard !samples.isEmpty else { return }
            // The GPU can't be used from the background, so each window picks what fits the app's state now.
            let gpu = await MainActor.run { UIApplication.shared.applicationState == .active }
            var result: WindowResult
            do {
                result = try decode(samples, offset: offset, gpu: gpu, language: language, modelPath: modelPath, engine: &engine, flag: flag)
            } catch where gpu && !flag.isCancelled {
                // The app left the foreground in the middle of the window: do it again on the CPU.
                log.info("Window failed on the GPU, retrying on the CPU: \(error.localizedDescription, privacy: .public)")
                result = try decode(samples, offset: offset, gpu: false, language: language, modelPath: modelPath, engine: &engine, flag: flag)
            }
            segments += result.segments
            if detected == nil { detected = result.language }
            offset += Double(samples.count) / AudioTools.speechRate
            samples.removeAll(keepingCapacity: true)
        }

        while let buffer = try reader.read() {
            try Task.checkCancellation()
            guard let data = buffer.floatChannelData?[0] else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            if samples.count >= windowSamples { try await flush() }
        }
        try await flush()
        return TranscriptionResult(segments: segments, detectedLanguage: language == nil ? detected : nil)
    }

    private static func decode(_ samples: [Float], offset: Double, gpu: Bool, language: String?, modelPath: String,
                               engine: inout WhisperEngine?, flag: CancelFlag) throws -> WindowResult {
        if engine?.gpu != gpu { engine = nil }
        if engine == nil { engine = try WhisperEngine(modelPath: modelPath, gpu: gpu) }
        guard let engine else { throw ProviderError(message: "The whisper model could not be loaded.") }
        return try engine.decode(samples, offset: offset, language: language, flag: flag)
    }
}

private struct WindowResult {
    var segments: [Segment]
    var language: String?
}

/// Set from the task being cancelled, read by whisper from its own threads.
private final class CancelFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// A loaded whisper model.
private final class WhisperEngine {
    let gpu: Bool
    private let context: OpaquePointer

    init(modelPath: String, gpu: Bool) throws {
        var params = whisper_context_default_params()
        params.use_gpu = gpu
        params.flash_attn = gpu
        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw ProviderError(message: "The whisper model could not be loaded. Delete it and download it again.")
        }
        self.context = context
        self.gpu = gpu
    }

    deinit { whisper_free(context) }

    func decode(_ samples: [Float], offset: Double, language: String?, flag: CancelFlag) throws -> WindowResult {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.translate = false
        params.abort_callback = { pointer in
            guard let pointer else { return false }
            return Unmanaged<CancelFlag>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }
        let code: Int32 = withExtendedLifetime(flag) {
            params.abort_callback_user_data = Unmanaged.passUnretained(flag).toOpaque()
            return (language ?? "auto").withCString { lang in
                params.language = lang
                return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        if flag.isCancelled { throw CancellationError() }
        guard code == 0 else { throw ProviderError(message: "whisper.cpp failed with code \(code).") }

        var segments: [Segment] = []
        for i in 0..<whisper_full_n_segments(context) {
            guard let c = whisper_full_get_segment_text(context, i) else { continue }
            let text = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(Segment(start: offset + Double(whisper_full_get_segment_t0(context, i)) / 100,
                                    end: offset + Double(whisper_full_get_segment_t1(context, i)) / 100, text: text))
        }
        let detected = whisper_lang_str(whisper_full_lang_id(context)).map { String(cString: $0) }
        return .init(segments: segments, language: detected)
    }
}
