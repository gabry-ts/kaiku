import AVFoundation
import AudioToolbox
import CoreAudio
import os

struct AudioCaptureError: LocalizedError {
    let message: String
    init(_ message: String, _ status: OSStatus? = nil) {
        self.message = status.map { "\(message) (OSStatus \($0)\(fourCC(Int($0))))" } ?? message
    }
    /// Wraps an underlying error, keeping its domain and code.
    init(_ message: String, underlying: Error) {
        self.message = "\(message): \(underlying.diagnosticDescription)"
    }
    var errorDescription: String? { message }
}

/// Captures all system audio output with a Core Audio process tap (macOS 14.2+)
/// routed through a private aggregate device, and hands the buffers to a TrackWriter.
///
/// When the default output changes (AirPods connect or disconnect, speakers picked in
/// Control Center) or the current output disappears, the tap and aggregate are rebuilt
/// on the new output while the recording goes on. The writer fills the gap with silence
/// and converts the new format, so the system track stays aligned with the mic.
/// Default devices and sample rates are never changed.
final class SystemAudioTap {
    struct Route {
        let name: String
        let isHeadphones: Bool
    }

    /// Called on a background queue at start (`initial` true) and after every rebuild.
    var onRoute: ((Route, _ initial: Bool) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private let queue = DispatchQueue(label: "kaiku.system-tap", qos: .userInitiated)
    /// Builds, tears down and handles device events, one at a time.
    private let control = DispatchQueue(label: "kaiku.system-tap.control", qos: .userInitiated)
    private let peak = OSAllocatedUnfairLock<Float>(initialState: 0)
    private var running = false
    private var outputID = AudioObjectID(kAudioObjectUnknown)
    private var pendingRebuild: DispatchWorkItem?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var aliveListener: (device: AudioObjectID, block: AudioObjectPropertyListenerBlock)?
    private(set) var rebuildCount = 0

    /// Peak level since the last read, 0...1.
    func readLevel() -> Float {
        peak.withLock { v in let r = v; v = 0; return r }
    }

    func start(writer: TrackWriter) throws {
        try control.sync {
            self.writer = writer
            do {
                try build()
            } catch {
                teardown()
                throw error
            }
            running = true
            installListeners()
        }
        reportRoute(initial: true)
    }

    /// Rebuilds the tap on the current default output now (also used by the self-test).
    func rebuildNow() {
        control.sync { rebuild() }
    }

    private func build() throws {
        // 1. Global stereo tap of every process, audio keeps playing normally.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Kaiku system audio"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw AudioCaptureError("Could not create system audio tap", status) }
        tapID = tap
        outputID = AudioDevices.defaultOutput?.id ?? AudioObjectID(kAudioObjectUnknown)

        // 2. Tap stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr else { throw AudioCaptureError("Could not read tap format", status) }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioCaptureError("Unsupported tap format")
        }

        // 3. Private, tap-only aggregate device. No real sub-device on purpose: adding the
        //    output device (e.g. a Bluetooth headset) would make the aggregate open its
        //    streams, which can reconfigure it (profile / sample rate) mid-call.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kaiku Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else { throw AudioCaptureError("Could not create aggregate device", status) }
        aggregateID = agg

        // 4. IO proc hands every input buffer to the writer (crash-safe CAF).
        Log.audio.info("System tap format: \(format.description, privacy: .public)")
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            guard let self, let writer = self.writer,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
            else { return }
            writer.write(buffer)
            self.peak.withLock { $0 = max($0, Self.peakLevel(inputData)) }
        }
        guard status == noErr else { throw AudioCaptureError("Could not create IO proc", status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw AudioCaptureError("Could not start system audio capture", status) }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        // Let any in-flight IO block finish.
        queue.sync {}
    }

    /// On the control queue.
    private func rebuild() {
        guard running else { return }
        writer?.expectGap()
        teardown()
        do {
            try build()
            rebuildCount += 1
            Log.audio.info("System audio tap rebuilt on \(AudioDevices.defaultOutput?.summary ?? "?", privacy: .public)")
        } catch {
            Log.audio.error("Rebuilding the system audio tap failed: \(error.diagnosticDescription, privacy: .public). Retrying.")
            teardown()
            schedule(after: 2)
            return
        }
        watchAlive(outputID)
        reportRoute(initial: false)
    }

    private func reportRoute(initial: Bool) {
        let device = AudioDevices.defaultOutput
        onRoute?(Route(name: device?.name ?? "Unknown output", isHeadphones: device?.isHeadphones ?? true), initial)
    }

    // MARK: Device events

    /// Debounced: connecting AirPods fires several events in a row.
    private func schedule(after delay: Double = 1) {
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            let current = AudioDevices.defaultOutput?.id ?? AudioObjectID(kAudioObjectUnknown)
            let alive = AudioDevices.all().first { $0.id == self.outputID }?.isAlive ?? false
            // Nothing to do if the output didn't actually change and is still there.
            if current == self.outputID && alive && self.aggregateID != kAudioObjectUnknown { return }
            self.rebuild()
        }
        pendingRebuild = item
        control.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func installListeners() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Log.audio.info("Default output device changed")
            self?.schedule()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, block) == noErr {
            defaultListener = block
        }
        watchAlive(outputID)
    }

    private func watchAlive(_ device: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if let old = aliveListener {
            AudioObjectRemovePropertyListenerBlock(old.device, &addr, control, old.block)
            aliveListener = nil
        }
        guard device != kAudioObjectUnknown else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Log.audio.info("Output device alive state changed")
            self?.schedule()
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, control, block) == noErr {
            aliveListener = (device, block)
        }
    }

    private func removeListeners() {
        if let block = defaultListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, block)
            defaultListener = nil
        }
        watchAlive(AudioObjectID(kAudioObjectUnknown))
    }

    private static func peakLevel(_ list: UnsafePointer<AudioBufferList>) -> Float {
        var m: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            var i = 0
            while i < count { m = max(m, abs(samples[i])); i += 4 }
        }
        return min(m, 1)
    }

    func stop() {
        control.sync {
            running = false
            pendingRebuild?.cancel()
            pendingRebuild = nil
            removeListeners()
            teardown()
        }
        // Release the writer on the IO queue so no write is in flight.
        queue.sync { self.writer?.close(); self.writer = nil }
    }
}

enum AudioFileSettings {
    /// AAC settings. No fixed bit rate on purpose: valid AAC bit rates depend on the
    /// sample rate (e.g. 64 kbps is rejected at 16 kHz, which Bluetooth headsets use),
    /// so the encoder picks one from the quality setting.
    static func aac(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: min(Int(channels), 2),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }
}
