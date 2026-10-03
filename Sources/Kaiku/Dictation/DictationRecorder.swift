import AVFoundation
import KaikuCore

/// Records one dictation from a microphone into memory, as 16 kHz mono 16-bit samples.
///
/// It has its own capture session, so it can run while a call is being recorded: macOS
/// lets several sessions read the same input, and the call recording carries on untouched.
final class DictationRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let sampleRate = 16_000

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "kaiku.dictation.audio", qos: .userInitiated)
    private let control = DispatchQueue(label: "kaiku.dictation.control", qos: .userInitiated)
    private let converter: LivePCMConverter
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var lastLevel: Float = 0

    override init() {
        // A fixed 16 kHz mono format always exists.
        converter = try! LivePCMConverter(sampleRate: Self.sampleRate)
        super.init()
    }

    /// Opens `device` and starts recording; the session starts running in the background.
    func start(device: AudioDevice) throws {
        guard let capture = AVCaptureDevice(uniqueID: device.uid) else {
            throw AudioCaptureError("Microphone \(device.name) not available")
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: capture) }
        catch { throw AudioCaptureError("Could not open microphone \(device.name)", underlying: error) }
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioCaptureError("Cannot record from \(device.name)")
        }
        session.addInput(input)
        session.addOutput(output)
        let rate = device.nominalSampleRate
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate >= 8_000 ? rate : 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        Log.audio.info("Dictation from \(device.summary, privacy: .public)")
        control.async { [session] in session.startRunning() }
    }

    /// Stops and returns everything recorded.
    func stop() -> [Int16] {
        control.sync { session.stopRunning() }
        // Buffers already handed to the delegate queue are kept.
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// Recent loudness, 0...1.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return lastLevel
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr,
              let converted = try? converter.convert(buffer), !converted.isEmpty else { return }
        var sum = 0.0
        for s in converted {
            let v = Double(s) / 32768
            sum += v * v
        }
        let rms = Float((sum / Double(converted.count)).squareRoot())
        let level = MicRecorder.normalize(db: 20 * log10(max(rms, 1e-6)))
        lock.lock()
        samples += converted
        lastLevel = level
        lock.unlock()
    }
}
