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
    /// Auto-started recording still waiting for a meaningful call window title.
    private var retitle: (source: String, user: MicUser, until: Date)?
    /// Process of each detected call at the last check, by source.
    private var callOwners: [String: MicUser] = [:]
    /// Processes using audio input at the last change, for the log.
    private var lastInputs: Set<String> = []
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
        /// Devices the process records from.
        let inputDevices: [AudioObjectID]
    }

    /// Starts or stops polling to match the setting.
    func apply() {
        if AppSettings.detectCalls {
            guard timer == nil else { return }
            detector = MeetingDetector()
            cache = SourceCache()
            retitle = nil
            lastInputs = []
            callOwners = [:]
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                Task { @MainActor in MeetingMonitor.shared.tick() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        logInputChanges()
        let users = Dictionary(Self.micUsers(excluding: ownPID, custom: AppSettings.customApps).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let sources = cache.update(active: Set(users.keys)) { key in Self.source(of: users[key]!) }
        let rules = AppSettings.sourceRules
        var calls: [String: DetectedCall] = [:]
        var owners: [String: MicUser] = [:]
        for (key, source) in sources.sorted(by: { $0.key < $1.key }) {
            AppSettings.noteSeen(source)
            guard rules.rule(for: source) != .never, calls[source] == nil else { continue }
            calls[source] = DetectedCall(source: source, app: users[key]!.appName)
            owners[source] = users[key]!
        }
        callOwners = owners
        let state = AppState.shared
        // Asking depends on notifications being allowed, which can change during the call.
        if state.isRecording, AppSettings.callEndMode == .ask { Permissions.shared.refreshNotifications() }
        let callEnd = AppSettings.callEndBehavior
        detector.autoStopAfter = Double(callEnd.autoStopSeconds(delay: AppSettings.detectAutoStopSeconds))
        let now = Date()
        for event in detector.update(active: Set(calls.keys), isRecording: state.isRecording, now: now) {
            Log.app.info("Call detection: \(String(describing: event), privacy: .public) (recording: \(state.isRecording), when the call ends: \(String(describing: callEnd), privacy: .public), delay: \(self.detector.autoStopAfter) s)")
            switch event {
            case .started(let source):
                guard var call = calls[source], let owner = owners[source] else { continue }
                call.windowTitle = Self.windowTitle(of: owner)
                if state.meetingStarted(call, rule: rules.rule(for: source)) {
                    retitle = (source, owner, now.addingTimeInterval(30))
                }
            case .ended(let source): state.meetingEnded(app: source, behavior: callEnd)
            case .autoStop: state.meetingAutoStop()
            }
        }
        retryTitle(now: now)
        if state.isRecording, AppSettings.followCallMicrophone, let mic = callMicrophone(source: state.currentCallSource) {
            state.followCallMicrophone(mic)
        }
    }

    /// Microphone used by the call of `source`, else by the only call going on.
    func callMicrophone(source: String?) -> AudioDevice? {
        let user = source.flatMap { callOwners[$0] } ?? (callOwners.count == 1 ? callOwners.values.first : nil)
        return user?.inputDevices.lazy.compactMap(AudioDevices.microphone(behind:)).first
    }

    /// Logs which processes use audio input whenever that changes, so a call that never
    /// seemed to end can be explained from the log (e.g. a browser keeping the mic open).
    private func logInputChanges() {
        let inputs = Set(Self.inputProcessBundleIDs())
        guard inputs != lastInputs else { return }
        lastInputs = inputs
        Log.app.info("Audio input in use by: \(inputs.isEmpty ? "nothing" : inputs.sorted().joined(separator: ", "), privacy: .public)")
    }

    /// Some apps name the call window late: re-read it during the first 30 s.
    private func retryTitle(now: Date) {
        guard let r = retitle else { return }
        guard now < r.until else { retitle = nil; return }
        // The recording starts asynchronously; retitleAutoStarted checks it is still ours.
        guard AppState.shared.isRecording else { return }
        if let title = Self.windowTitle(of: r.user).flatMap({ CallTitle.clean($0, source: r.source) }) {
            AppState.shared.retitleAutoStarted(to: title)
            retitle = nil
        }
    }

    static func windowTitle(of user: MicUser) -> String? {
        WindowTitle.front(pid: user.pid, bundleID: user.bundleID, bundlePrefixes: user.bundlePrefixes)
    }

    /// Source of a mic user: its native source, or the browser's front window title.
    static func source(of user: MicUser) -> String {
        guard user.isBrowser else { return user.key }
        return CallSource.resolve(bundleID: user.bundleID, windowTitle: windowTitle(of: user),
                                  sites: AppSettings.customWebsites) ?? user.appName
    }

    /// Known call apps and browsers whose processes are currently capturing audio input.
    nonisolated static func micUsers(excluding pid: pid_t, custom: [CustomApp]) -> [MicUser] {
        var result: [MicUser] = []
        for process in processObjects() {
            let processPID = pidOf(process)
            guard uint32(process, kAudioProcessPropertyIsRunningInput) != 0, processPID != pid,
                  let bundle = string(process, kAudioProcessPropertyBundleID) else { continue }
            let user: MicUser
            if let native = CallSource.native(bundleID: bundle, custom: custom) {
                user = MicUser(key: native.name, appName: native.name, bundleID: bundle, pid: processPID,
                               bundlePrefixes: native.bundlePrefixes, isBrowser: false, inputDevices: inputDevices(of: process))
            } else if let browser = MeetingApp.match(bundleID: bundle), browser.isBrowser {
                user = MicUser(key: browser.id, appName: browser.name, bundleID: bundle, pid: processPID,
                               bundlePrefixes: browser.bundlePrefixes, isBrowser: true, inputDevices: inputDevices(of: process))
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

    private nonisolated static func inputDevices(of process: AudioObjectID) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(process, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &ids) == noErr else { return [] }
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
