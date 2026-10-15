import AVFoundation
import AudioToolbox
import CoreAudio
import KaikuCore
import os

/// Captures all system audio output with a Core Audio process tap (macOS 14.2+)
/// routed through a private aggregate device, and hands the buffers to a TrackWriter.
///
/// When the default output changes (AirPods connect or disconnect, speakers picked in
/// Control Center) or the current output disappears, the tap and aggregate are rebuilt
/// on the new output while the recording goes on. The writer fills the gap with silence
/// and converts the new format, so the system track stays aligned with the mic.
/// Default devices and sample rates are never changed.
///
/// The meeting bot uses it on its own Chrome processes only, muted on the speakers unless
/// you listen in. Every other tap leaves those processes out.
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
    /// The processes to tap instead of all output (the meeting bot's Chrome), read at every build.
    private let processes: (() -> [AudioObjectID])?
    private var muted: Bool
    private var tapDescription: CATapDescription?
    private var excludeObserver: NSObjectProtocol?

    /// Audio processes of the meeting bot, left out of every tap but its own.
    static let botProcesses = OSAllocatedUnfairLock<[AudioObjectID]>(initialState: [])
    static let botProcessesChanged = Notification.Name("kaiku.botProcessesChanged")

    init(processes: (() -> [AudioObjectID])? = nil, muted: Bool = false) {
        self.processes = processes
        self.muted = muted
    }

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
        if processes == nil {
            // The bot joined or left: leave its processes out again.
            excludeObserver = NotificationCenter.default.addObserver(
                forName: Self.botProcessesChanged, object: nil, queue: nil) { [weak self] _ in self?.refresh() }
        }
        reportRoute(initial: true)
    }

    /// Rebuilds the tap on the current default output now (also used by the self-test).
    func rebuildNow() {
        control.sync { rebuild() }
    }

    /// Rebuilds the tap soon, e.g. when the processes to tap or leave out changed.
    func refresh() {
        control.async { [weak self] in self?.rebuild() }
    }

    /// Plays the tapped processes on the speakers too, or mutes them again, without
    /// stopping the capture.
    func setMuted(_ value: Bool) {
        control.async { [weak self] in
            guard let self, self.muted != value else { return }
            self.muted = value
            guard self.tapID != kAudioObjectUnknown, let desc = self.tapDescription else { return }
            desc.muteBehavior = value ? .mutedWhenTapped : .unmuted
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyDescription,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var ref = desc
            let status = withUnsafeMutablePointer(to: &ref) {
                AudioObjectSetPropertyData(self.tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
            if status != noErr {
                Log.audio.error("Changing the tap mute failed (\(status)), rebuilding it")
                self.rebuild()
            }
        }
    }

    /// The Core Audio process objects of `pid` and its descendants (Chrome plays audio
    /// from a helper process).
    static func audioProcesses(descendantsOf pid: pid_t) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var processPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &processPID) == noErr else { return false }
            var current = processPID
            // Walk up the parents, a few levels at most.
            for _ in 0..<6 {
                if current == pid { return true }
                guard current > 1, let parent = parentPID(of: current) else { return false }
                current = parent
            }
            return false
        }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private func build() throws {
        // 1. Global stereo tap of every process but the bot's, audio keeps playing normally.
        //    The bot's tap takes only its processes, muted unless you listen in.
        let desc = processes.map { CATapDescription(stereoMixdownOfProcesses: $0()) }
            ?? CATapDescription(stereoGlobalTapButExcludeProcesses: Self.botProcesses.withLock { $0 })
        desc.uuid = UUID()
        desc.name = processes == nil ? "Kaiku system audio" : "Kaiku meeting bot"
        desc.muteBehavior = muted ? .mutedWhenTapped : .unmuted
        desc.isPrivate = true
        tapDescription = desc

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
        tapDescription = nil
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
        if let excludeObserver { NotificationCenter.default.removeObserver(excludeObserver) }
        excludeObserver = nil
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
