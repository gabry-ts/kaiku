import AVFoundation
import KaikuCore
import Observation
import UIKit
import WidgetKit
import os

/// Records the microphone into a call folder, with pause, resume and bookmarks.
/// The audio goes to system.caf while recording (readable after a crash) and is converted to system.m4a on stop.
@MainActor
@Observable
final class MeetingRecorder: RecordingIntentHandler {
    enum State { case idle, recording, paused }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { publishState() } }
    }
    private(set) var bookmarks: [Bookmark] = []
    /// True while the recording is being converted and saved after Stop.
    private(set) var isFinishing = false
    private(set) var error: String?
    var errorMessage: String? { error }
    var isActive: Bool { state != .idle }
    private(set) var folder: RecordingFolder?

    /// Called with the folder once its audio is saved.
    var onFinished: ((RecordingFolder) -> Void)?

    private let engine = AVAudioEngine()
    private var writer: CAFWriter?
    private var meta: RecordingMeta?
    private var observers: [Task<Void, Never>] = []
    private var pausedByInterruption = false
    private let activity = RecordingActivityController()

    /// Seconds of audio recorded so far; paused time is not counted.
    var elapsed: Double { writer?.seconds ?? 0 }

    init() {
        // A recording the app lost in a crash must not leave the toggle on.
        AppGroup.defaults.set(false, forKey: AppGroup.isRecordingKey)
    }

    private func publishState() {
        AppGroup.defaults.set(state != .idle, forKey: AppGroup.isRecordingKey)
        ControlCenter.shared.reloadAllControls()
    }

    // MARK: Start, pause, stop

    func start() async {
        guard state == .idle, !isFinishing else { return }
        error = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Microphone access is off. Turn it on in Settings > Kaiku."
            return
        }
        do {
            try begin()
        } catch {
            teardown()
            self.error = error.localizedDescription
        }
    }

    func pause() {
        guard state == .recording else { return }
        pauseRecording(at: elapsed)
        pausedByInterruption = false
    }

    func resume() {
        guard state == .paused else { return }
        do {
            try resumeRecording()
            pausedByInterruption = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addBookmark() {
        guard state != .idle else { return }
        bookmarks.append(Bookmark(time: elapsed))
        meta?.bookmarks = bookmarks
        saveMeta()
        activity.setBookmarks(bookmarks.count)
    }

    func stop() async {
        guard state != .idle, let folder, var meta = meta else { return }
        let seconds = elapsed
        if var pauses = meta.pauses, let last = pauses.last, last.end == nil {
            pauses[pauses.count - 1].end = Date()
            meta.pauses = pauses
        }
        teardown()
        isFinishing = true
        meta.status = .recovered
        meta.durationSeconds = seconds
        meta.bookmarks = bookmarks.isEmpty ? nil : bookmarks
        let result = await Task.detached { Self.finalize(folder) }.value
        switch result {
        case .success(let duration):
            meta.durationSeconds = duration ?? seconds
        case .failure(let failure):
            meta.status = .error
            meta.error = failure.localizedDescription
            error = failure.localizedDescription
        }
        try? folder.saveMeta(meta)
        isFinishing = false
        self.folder = nil
        self.meta = nil
        bookmarks = []
        if meta.status != .error { onFinished?(folder) }
    }

    // MARK: Engine

    private func begin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)

        let date = Date()
        let title = Naming.defaultTitle(date: date).replacingOccurrences(of: "Call", with: "Meeting")
        let folder = try RecordingFolder.create(base: PhoneSettings.baseFolder, date: date, title: title)
        let meta = RecordingMeta(title: title, date: date, durationSeconds: 0, language: PhoneSettings.language,
                                 status: .recording, source: "iPhone")
        try folder.saveMeta(meta)
        self.folder = folder
        self.meta = meta
        bookmarks = []
        writer = CAFWriter(url: folder.systemRawURL)

        try startEngine()
        state = .recording
        activity.start(title: title, at: date)
        UIApplication.shared.isIdleTimerDisabled = true
        observe()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        guard let writer else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in writer.write(buffer) }
        engine.prepare()
        try engine.start()
    }

    private func pauseRecording(at seconds: Double) {
        writer?.setPaused(true)
        state = .paused
        activity.pause()
        meta?.status = .paused
        meta?.pauses = (meta?.pauses ?? []) + [PauseInterval(start: Date(), offset: seconds)]
        saveMeta()
    }

    private func resumeRecording() throws {
        if !engine.isRunning {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
        }
        writer?.setPaused(false)
        state = .recording
        activity.resume()
        meta?.status = .recording
        if var pauses = meta?.pauses, let last = pauses.last, last.end == nil {
            pauses[pauses.count - 1].end = Date()
            meta?.pauses = pauses
        }
        saveMeta()
    }

    private func teardown() {
        observers.forEach { $0.cancel() }
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
        state = .idle
        activity.end()
        pausedByInterruption = false
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func saveMeta() {
        guard let folder, let meta else { return }
        try? folder.saveMeta(meta)
    }

    // MARK: Interruptions and route changes

    private func observe() {
        let center = NotificationCenter.default
        observers = [
            Task { [weak self] in
                for await note in center.notifications(named: AVAudioSession.interruptionNotification) {
                    let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                    let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
                    self?.interruption(type, options)
                }
            },
            Task { [weak self] in
                // The microphone or the sample rate changed (headphones, Bluetooth): the engine stops and must be restarted.
                for await _ in center.notifications(named: .AVAudioEngineConfigurationChange) {
                    self?.configurationChanged()
                }
            },
        ]
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, _ options: AVAudioSession.InterruptionOptions?) {
        switch type {
        case .began:
            guard state == .recording else { return }
            pauseRecording(at: elapsed)
            pausedByInterruption = true
        case .ended:
            guard state == .paused, pausedByInterruption, options?.contains(.shouldResume) == true else { return }
            resume()
        default:
            break
        }
    }

    private func configurationChanged() {
        guard state == .recording, !engine.isRunning else { return }
        do {
            try startEngine()
        } catch {
            pauseRecording(at: elapsed)
            self.error = "The microphone changed and recording could not continue: \(error.localizedDescription)"
        }
    }

    // MARK: Saving

    /// Converts system.caf to system.m4a, keeping the raw file when anything goes wrong. Blocking.
    nonisolated private static func finalize(_ folder: RecordingFolder) -> Result<Double?, Error> {
        let raw = folder.systemRawURL
        guard FileManager.default.fileExists(atPath: raw.path) else { return .success(nil) }
        if (AudioFiles.duration(raw) ?? 0) <= 0 {
            try? FileManager.default.removeItem(at: raw)
            return .failure(AudioCaptureError("No audio was recorded."))
        }
        do {
            let duration = try AudioFiles.convertToM4A(raw, output: folder.systemURL)
            try FileManager.default.removeItem(at: raw)
            return .success(duration)
        } catch {
            return .failure(AudioCaptureError("Could not save the audio. The raw recording is kept in the call folder.", underlying: error))
        }
    }

    /// Saves the audio of recordings the app left open (a crash or a force quit) and marks them as recovered.
    /// Blocking: call off the main thread. Calls that started after `launch` are being recorded now and are left alone.
    nonisolated static func recoverInterrupted(base: URL, launch: Date) {
        for folder in RecordingFolder.scan(base: base) {
            guard var meta = folder.loadMeta(), meta.status == .recording || meta.status == .paused, meta.date < launch else { continue }
            if var pauses = meta.pauses, let last = pauses.last, last.end == nil {
                pauses[pauses.count - 1].end = last.start
                meta.pauses = pauses
            }
            switch finalize(folder) {
            case .success(let duration):
                if let duration { meta.durationSeconds = duration; meta.status = .recovered; meta.error = nil } else if !folder.audioURLs.isEmpty {
                    meta.status = .recovered
                } else {
                    meta.status = .error
                    meta.error = "The recording was interrupted and no audio was found."
                }
            case .failure(let failure):
                meta.status = .error
                meta.error = failure.localizedDescription
            }
            try? folder.saveMeta(meta)
        }
    }
}

/// Writes microphone buffers to a 16-bit PCM CAF, converting them when the input format changes mid-recording.
private final class CAFWriter: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.gabrielepartiti.kaiku.ios", category: "recording")
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var paused = false
    private var frames: AVAudioFramePosition = 0
    private var rate: Double = 0

    init(url: URL) {
        self.url = url
    }

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return rate > 0 ? Double(frames) / rate : 0
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !paused, buffer.frameLength > 0 else { return }
        do {
            if file == nil {
                rate = buffer.format.sampleRate
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            guard let file else { return }
            let target = file.processingFormat
            if buffer.format == target {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
                return
            }
            if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var given = false
            var failure: NSError?
            converter.convert(to: out, error: &failure) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if failure == nil, out.frameLength > 0 {
                try file.write(from: out)
                frames += AVAudioFramePosition(out.frameLength)
            }
        } catch {
            Self.log.error("Writing audio failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}
