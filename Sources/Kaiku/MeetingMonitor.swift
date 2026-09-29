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
    private var cache = SourceCache()
    private let ownPID = getpid()

    /// A known call app (native or browser) whose process is capturing audio input.
    struct MicUser {
        /// Source name for native apps, browser id for browsers.
        let key: String
        /// App the process belongs to, e.g. "Google Chrome".
        let appName: String
        let bundleID: String
        let pid: pid_t
        let bundlePrefixes: [String]
        let isBrowser: Bool
    }

    /// Starts or stops polling to match the setting.
    func apply() {
        if AppSettings.detectCalls {
            guard timer == nil else { return }
            detector = MeetingDetector()
            cache = SourceCache()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                Task { @MainActor in MeetingMonitor.shared.tick() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let users = Dictionary(Self.micUsers(excluding: ownPID).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let sources = cache.update(active: Set(users.keys)) { key in Self.source(of: users[key]!) }
        let rules = AppSettings.sourceRules
        var calls: [String: DetectedCall] = [:]
        for (key, source) in sources.sorted(by: { $0.key < $1.key }) {
            AppSettings.noteSeen(source)
            guard rules.rule(for: source) != .never, calls[source] == nil else { continue }
            calls[source] = DetectedCall(source: source, app: users[key]!.appName)
        }
        detector.autoStopAfter = Double(AppSettings.detectAutoStopSeconds)
        let state = AppState.shared
        for event in detector.update(active: Set(calls.keys), isRecording: state.isRecording, now: Date()) {
            switch event {
            case .started(let source):
                if let call = calls[source] { state.meetingStarted(call, rule: rules.rule(for: source)) }
            case .ended(let source): state.meetingEnded(app: source)
            case .autoStop: state.meetingAutoStop()
            }
        }
    }

    /// Source of a mic user: its native source, or the browser's front window title.
    static func source(of user: MicUser) -> String {
        guard user.isBrowser else { return user.key }
        let title = WindowTitle.front(pid: user.pid, bundleID: user.bundleID, bundlePrefixes: user.bundlePrefixes)
        return CallSource.resolve(bundleID: user.bundleID, windowTitle: title) ?? user.appName
    }

    /// Known call apps and browsers whose processes are currently capturing audio input.
    nonisolated static func micUsers(excluding pid: pid_t) -> [MicUser] {
        var result: [MicUser] = []
        for process in processObjects() {
            let processPID = pidOf(process)
            guard uint32(process, kAudioProcessPropertyIsRunningInput) != 0, processPID != pid,
                  let bundle = string(process, kAudioProcessPropertyBundleID) else { continue }
            let user: MicUser
            if let native = CallSource.native(bundleID: bundle) {
                user = MicUser(key: native.name, appName: native.name, bundleID: bundle, pid: processPID,
                               bundlePrefixes: native.bundlePrefixes, isBrowser: false)
            } else if let browser = MeetingApp.match(bundleID: bundle), browser.isBrowser {
                user = MicUser(key: browser.id, appName: browser.name, bundleID: bundle, pid: processPID,
                               bundlePrefixes: browser.bundlePrefixes, isBrowser: true)
            } else {
                continue
            }
            if !result.contains(where: { $0.key == user.key }) { result.append(user) }
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
