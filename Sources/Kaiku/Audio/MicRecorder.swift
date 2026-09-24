import AVFoundation

/// Records one specific input device with AVCaptureSession into a crash-safe CAF.
/// Only that device is opened: the system default input (e.g. a Bluetooth headset,
/// which would drop to its low-quality call profile) is never touched.
final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "kaiku.mic", qos: .userInitiated)
    private var writer: TrackWriter?
    private var recording = false
    private var observers: [NSObjectProtocol] = []
    /// The device being recorded.
    private(set) var device: AudioDevice?
    /// Called (on an arbitrary thread) when the device disappears or the session fails.
    var onLost: (() -> Void)?

    func start(writer: TrackWriter, device: AudioDevice) throws {
        session.beginConfiguration()
        do {
            try configure(device)
        } catch {
            session.commitConfiguration()
            throw error
        }
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioCaptureError("Cannot record microphone")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()

        self.writer = writer
        observe()
        session.startRunning()
        recording = true
    }

    /// Switches to another input without stopping the recording. The writer pads the
    /// switch time with silence and converts the new device's sample rate.
    func switchTo(_ newDevice: AudioDevice) throws {
        writer?.expectGap()
        session.beginConfiguration()
        let previous = session.inputs
        previous.forEach { session.removeInput($0) }
        do {
            try configure(newDevice)
        } catch {
            previous.forEach { if session.canAddInput($0) { session.addInput($0) } }
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
    }

    /// Adds the input for `device` and sets the output format. Inside begin/commitConfiguration.
    private func configure(_ device: AudioDevice) throws {
        guard let capture = AVCaptureDevice(uniqueID: device.uid) else {
            throw AudioCaptureError("Microphone \(device.name) not available to capture")
        }
        Log.audio.info("Mic device: \(device.summary, privacy: .public)")
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: capture) }
        catch { throw AudioCaptureError("Could not open microphone \(device.name)", underlying: error) }
        guard session.canAddInput(input) else { throw AudioCaptureError("Cannot use microphone \(device.name)") }
        session.addInput(input)
        self.device = device
        let rate = device.nominalSampleRate
        // Mono float PCM at the device rate; the writer stores it as 16-bit CAF.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate >= 8_000 ? rate : 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] n in
            guard let self, let d = n.object as? AVCaptureDevice, d.uniqueID == self.device?.uid else { return }
            Log.audio.error("Microphone disconnected: \(d.localizedName, privacy: .public)")
            self.onLost?()
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let error = n.userInfo?[AVCaptureSessionErrorKey] as? Error
            Log.audio.error("Microphone session error: \(error?.diagnosticDescription ?? "unknown", privacy: .public)")
            self?.onLost?()
        })
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer, let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        writer.write(buffer)
    }

    /// Current average level, 0...1 (from the capture connection meters).
    func readLevel() -> Float {
        guard recording, let channel = output.connections.first?.audioChannels.first else { return 0 }
        return MicRecorder.normalize(db: channel.averagePowerLevel)
    }

    /// Maps -50...0 dBFS to 0...1.
    static func normalize(db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return min(max((db + 50) / 50, 0), 1)
    }

    /// Stops capture and closes the file. Safe to call more than once.
    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        session.stopRunning()
        recording = false
        // Drain buffers already queued, then close the file.
        queue.sync { }
        writer?.close()
    }
}

/// Records mic and system audio to two separate crash-safe CAF files.
/// Keeps going if one of the two fails; throws only if neither could start.
final class CallRecorder {
    private let mic = MicRecorder()
    private let system = SystemAudioTap()
    private let gate = PauseGate()
    private var micStarted = false
    private var systemStarted = false
    private var writers: [TrackWriter] = []
    private let control = DispatchQueue(label: "kaiku.recorder.control")
    private var stopped = false
    /// Where the call audio plays, at start and after every change (background queue).
    var onRoute: ((SystemAudioTap.Route, _ initial: Bool) -> Void)?
    /// After the mic was lost: the device switched to, or nil if none is left (background queue).
    var onMicFallback: ((_ lost: String, _ now: AudioDevice?) -> Void)?
    /// Human readable problems with either track (nil when both started as configured).
    private(set) var warnings: [String] = []

    /// - Parameter micDevice: nil records system audio only.
    func start(micURL: URL, systemURL: URL, micDevice: AudioDevice?) throws {
        if let micDevice {
            do {
                let w = TrackWriter(url: micURL, gate: gate)
                mic.onLost = { [weak self] in self?.control.async { self?.handleMicLost() } }
                try mic.start(writer: w, device: micDevice)
                writers.append(w)
                micStarted = true
            } catch {
                warnings.append("Microphone (\(micDevice.name)): \(error.diagnosticDescription)")
            }
        }
        do {
            let w = TrackWriter(url: systemURL, gate: gate)
            system.onRoute = { [weak self] route, initial in self?.onRoute?(route, initial) }
            try system.start(writer: w)
            writers.append(w)
            systemStarted = true
            Log.audio.info("System audio tap started")
        } catch {
            warnings.append("System audio tap: \(error.diagnosticDescription)")
        }
        warnings.forEach { w in Log.audio.error("\(w, privacy: .public)") }
        if !micStarted && !systemStarted {
            throw AudioCaptureError(warnings.isEmpty ? "Nothing to record" : warnings.joined(separator: "\n"))
        }
    }

    var micLevel: Float { micStarted && !gate.isPaused ? mic.readLevel() : 0 }
    var systemLevel: Float {
        let level = system.readLevel()
        return gate.isPaused ? 0 : level
    }
    var hasMic: Bool { micStarted }

    /// Drops audio on both tracks while paused.
    func setPaused(_ paused: Bool) { gate.set(paused) }

    var micDevice: AudioDevice? { micStarted ? mic.device : nil }

    /// Switches the microphone mid-call (panel picker). Blocking; call off the main thread.
    func switchMicrophone(to device: AudioDevice) throws {
        try control.sync {
            guard micStarted, !stopped else { throw AudioCaptureError("The microphone isn't being recorded") }
            guard device.uid != mic.device?.uid else { return }
            try mic.switchTo(device)
        }
    }

    /// Seconds written per track: [mic, system] when both run (self-test).
    var trackSeconds: [Double] { writers.map(\.seconds) }

    /// Reopens the current mic through the hot-swap path (self-test).
    func reopenMicrophone() throws {
        try control.sync {
            guard micStarted, let d = mic.device else { return }
            try mic.switchTo(d)
        }
    }

    /// Rebuilds the system tap now, as an output change would (self-test).
    func rebuildSystemTap() { if systemStarted { system.rebuildNow() } }

    /// On the control queue: the mic vanished, move to the automatic choice (never Bluetooth).
    /// The original mic is not taken back if it returns, to keep the call stable.
    private func handleMicLost() {
        guard micStarted, !stopped, let lost = mic.device else { return }
        // Ignore a late notification for a device we already left.
        if let still = AudioDevices.inputs().first(where: { $0.uid == lost.uid }), still.isAlive,
           AVCaptureDevice(uniqueID: lost.uid)?.isConnected == true { return }
        let fallback = AudioDevices.fallbackMicrophone(excluding: lost.uid)
        if let fallback {
            do {
                try mic.switchTo(fallback)
                Log.audio.info("Switched microphone to \(fallback.name, privacy: .public)")
            } catch {
                Log.audio.error("Fallback microphone failed: \(error.diagnosticDescription, privacy: .public)")
                onMicFallback?(lost.name, nil)
                return
            }
        }
        onMicFallback?(lost.name, fallback)
    }

    /// Stops both tracks and closes their files (fast, no conversion).
    func stop() {
        control.sync { stopped = true }
        if systemStarted { system.stop() }
        if micStarted { mic.stop() }
        writers.forEach { $0.close() }
    }
}

/// Live input level for one device, used by the microphone test in Settings.
/// Opens only that device, and only while running.
@MainActor
final class MicLevelMonitor: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published private(set) var level: Float = 0
    @Published private(set) var running = false
    @Published private(set) var error: String?

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "kaiku.mic-monitor")

    func start(device: AudioDevice) {
        stop()
        error = nil
        guard let capture = AVCaptureDevice(uniqueID: device.uid),
              let input = try? AVCaptureDeviceInput(device: capture) else {
            error = "Can't open \(device.name)"
            return
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            error = "Can't use \(device.name)"
            return
        }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        self.session = session
        self.output = output
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let ch = self.output?.connections.first?.audioChannels.first else { return }
                self.level = MicRecorder.normalize(db: ch.averagePowerLevel)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session?.stopRunning()
        session = nil
        output = nil
        running = false
        level = 0
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
