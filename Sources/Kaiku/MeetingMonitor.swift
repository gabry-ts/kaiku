import CoreAudio
import Foundation
import KaikuCore

/// Watches which apps are using a microphone, via the Core Audio process list
/// (macOS 14+). It only reads properties: no audio device is opened, so it never
/// touches the mic or a Bluetooth headset. Our own process is ignored.
@MainActor
final class MeetingMonitor {
    static let shared = MeetingMonitor()

    private var timer: Timer?
    private var detector = MeetingDetector()
    private let ownPID = getpid()

    /// Starts or stops polling to match the setting.
    func apply() {
        if AppSettings.detectCalls {
            guard timer == nil else { return }
            detector = MeetingDetector()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                Task { @MainActor in MeetingMonitor.shared.tick() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let disabled = Set(AppSettings.detectDisabledApps)
        let active = Set(Self.appsUsingMicrophone(excluding: ownPID).map(\.id)).subtracting(disabled)
        detector.autoStopAfter = Double(AppSettings.detectAutoStopSeconds)
        let state = AppState.shared
        for event in detector.update(active: active, isRecording: state.isRecording, now: Date()) {
            switch event {
            case .started(let id): state.meetingStarted(app: Self.name(id))
            case .ended(let id): state.meetingEnded(app: Self.name(id))
            case .autoStop: state.meetingAutoStop()
            }
        }
    }

    private static func name(_ id: String) -> String {
        MeetingApp.known.first { $0.id == id }?.name ?? id
    }

    /// Known meeting apps whose processes are currently capturing audio input.
    nonisolated static func appsUsingMicrophone(excluding pid: pid_t) -> [MeetingApp] {
        var result: [MeetingApp] = []
        for process in processObjects() {
            guard uint32(process, kAudioProcessPropertyIsRunningInput) != 0,
                  pidOf(process) != pid,
                  let bundle = string(process, kAudioProcessPropertyBundleID),
                  let app = MeetingApp.match(bundleID: bundle),
                  !result.contains(app) else { continue }
            result.append(app)
        }
        return result
    }

    /// Bundle ids of every process using audio input (for diagnostics).
    nonisolated static func inputProcessBundleIDs() -> [String] {
        processObjects().filter { uint32($0, kAudioProcessPropertyIsRunningInput) != 0 }
            .map { string($0, kAudioProcessPropertyBundleID) ?? "pid \(pidOf($0))" }
    }

    private nonisolated static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    private nonisolated static func pidOf(_ id: AudioObjectID) -> pid_t {
        var value = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    private nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        let s = v.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }
}
