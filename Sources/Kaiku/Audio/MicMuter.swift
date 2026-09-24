import CoreAudio
import Foundation
import KaikuCore

/// Mutes every microphone on the Mac at the hardware-property level, so call apps still
/// show you as unmuted but send silence. Only device properties are changed (mute switch,
/// or input volume 0): no device is opened, so Bluetooth headsets don't switch profile.
/// The previous state is saved per device before changing anything, restored on unmute,
/// on quit, and on the next launch after a crash.
@MainActor
final class MicMuter: ObservableObject {
    static let shared = MicMuter()

    @Published private(set) var isMuted = false
    /// Names of input devices that can be neither muted nor turned down.
    @Published private(set) var unsupported: [String] = []
    /// Called on every change of `isMuted` (for mute intervals in the recording).
    var onChange: ((Bool) -> Void)?

    private static let savedKey = "mutedDevicesState"
    private static let mutedKey = "micsMuted"

    private var methods: [String: (id: AudioObjectID, method: MuteMethod)] = [:]
    private var listeners: [(id: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    private var saved: [MicDeviceState] {
        get {
            AppSettings.defaults.data(forKey: Self.savedKey)
                .flatMap { try? JSONDecoder().decode([MicDeviceState].self, from: $0) } ?? []
        }
        set { AppSettings.defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.savedKey) }
    }

    func toggle() { isMuted ? unmute() : mute() }

    /// How a device is being silenced right now, if it is.
    func method(for uid: String) -> MuteMethod? { methods[uid]?.method }

    func mute() {
        guard !isMuted else { return }
        isMuted = true
        AppSettings.defaults.set(true, forKey: Self.mutedKey)
        muteAll()
        watchDeviceList(true)
        Log.audio.info("All microphones muted (\(self.methods.count) devices, \(self.unsupported.count) unsupported)")
        onChange?(true)
    }

    func unmute() {
        guard isMuted || AppSettings.defaults.bool(forKey: Self.mutedKey) else { return }
        watchDeviceList(false)
        removeListeners()
        restoreSaved()
        methods = [:]
        unsupported = []
        isMuted = false
        onChange?(false)
    }

    /// At launch: if the app died while muted, put every microphone back as it was.
    func restoreAfterCrash() {
        guard AppSettings.defaults.bool(forKey: Self.mutedKey) else { return }
        Log.audio.error("Microphones were left muted by a previous run; restoring \(self.saved.count) devices")
        restoreSaved()
    }

    // MARK: Mute and restore

    private func muteAll() {
        var toSave: [MicDeviceState] = []
        var failing: [String] = []
        var fresh: [(device: AudioDevice, caps: MuteCapabilities)] = []
        for device in Self.inputDevices() where methods[device.uid] == nil {
            let caps = Self.capabilities(device)
            if MutePlanner.method(caps) == .unsupported {
                failing.append(device.name)
                continue
            }
            // Save before changing anything.
            toSave.append(MutePlanner.stateToSave(uid: device.uid, name: device.name, caps: caps,
                                                  mute: Self.muteValue(device.id), volumes: Self.volumes(device)))
            fresh.append((device, caps))
        }
        saved = MutePlanner.merge(saved, adding: toSave)
        for (device, caps) in fresh {
            var method = MutePlanner.method(caps)
            apply(method, to: device.id)
            if method == .mute && Self.muteValue(device.id) != 1 {
                // Accepted but ignored (some virtual devices): turn the volume down instead.
                Self.setUInt32(device.id, kAudioDevicePropertyMute, 0, Self.savedMute(device.uid, in: saved) ?? 0)
                method = MutePlanner.fallback(caps)
                apply(method, to: device.id)
                let silent = !MutePlanner.needsReapply(method, mute: nil, volumes: Self.volumes(id: device.id, elements: Self.elements(method)))
                if method == .unsupported || !silent {
                    failing.append(device.name)
                    continue
                }
            }
            methods[device.uid] = (device.id, method)
            addListeners(uid: device.uid, id: device.id, method: method)
        }
        unsupported = Array(Set(unsupported + failing)).sorted()
    }

    private static func savedMute(_ uid: String, in states: [MicDeviceState]) -> UInt32? {
        states.first { $0.uid == uid }?.mute
    }

    nonisolated static func elements(_ method: MuteMethod) -> [UInt32] {
        if case .volume(let e) = method { return e }
        return []
    }

    private func restoreSaved() {
        let states = saved
        let devices = AudioDevices.all()
        for state in states {
            guard let device = devices.first(where: { $0.uid == state.uid }) else {
                Log.audio.info("Not restoring \(state.name, privacy: .public): not connected")
                continue
            }
            if let m = state.mute { Self.setUInt32(device.id, kAudioDevicePropertyMute, 0, m) }
            for (key, value) in state.volumes {
                if let element = UInt32(key) { Self.setFloat(device.id, kAudioDevicePropertyVolumeScalar, element, value) }
            }
        }
        AppSettings.defaults.removeObject(forKey: Self.savedKey)
        AppSettings.defaults.set(false, forKey: Self.mutedKey)
        Log.audio.info("Microphones restored (\(states.count) devices)")
    }

    private func apply(_ method: MuteMethod, to id: AudioObjectID) {
        switch method {
        case .mute: Self.setUInt32(id, kAudioDevicePropertyMute, 0, 1)
        case .volume(let elements): elements.forEach { Self.setFloat(id, kAudioDevicePropertyVolumeScalar, $0, 0) }
        case .unsupported: break
        }
    }

    /// Re-applies the mute if an app (Zoom or Chrome automatic gain) raised it.
    private func enforce(_ uid: String) {
        guard isMuted, let entry = methods[uid] else { return }
        let volumes = Self.volumes(id: entry.id, elements: Self.elements(entry.method))
        if MutePlanner.needsReapply(entry.method, mute: Self.muteValue(entry.id), volumes: volumes) {
            Log.audio.info("Microphone \(uid, privacy: .public) was unmuted by another app; muting again")
            apply(entry.method, to: entry.id)
        }
    }

    // MARK: Listeners

    private func addListeners(uid: String, id: AudioObjectID, method: MuteMethod) {
        var addresses: [AudioObjectPropertyAddress] = []
        switch method {
        case .mute:
            addresses.append(Self.address(kAudioDevicePropertyMute, 0))
        case .volume(let elements):
            addresses += elements.map { Self.address(kAudioDevicePropertyVolumeScalar, $0) }
        case .unsupported:
            return
        }
        for var addr in addresses {
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { MicMuter.shared.enforce(uid) }
            }
            if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
                listeners.append((id, addr, block))
            }
        }
    }

    private func removeListeners() {
        for var l in listeners { AudioObjectRemovePropertyListenerBlock(l.id, &l.address, DispatchQueue.main, l.block) }
        listeners = []
    }

    /// Devices connected while muted get muted too.
    private func watchDeviceList(_ on: Bool) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let block = deviceListListener {
            AudioObjectRemovePropertyListenerBlock(system, &addr, DispatchQueue.main, block)
            deviceListListener = nil
        }
        guard on else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated {
                guard MicMuter.shared.isMuted else { return }
                // Forget devices that went away, mute the new ones.
                let present = Set(MicMuter.inputDevices().map(\.uid))
                MicMuter.shared.methods = MicMuter.shared.methods.filter { present.contains($0.key) }
                MicMuter.shared.muteAll()
            }
        }
        if AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main, block) == noErr { deviceListListener = block }
    }

    // MARK: Core Audio helpers

    /// Real input devices; our own private tap aggregate and other aggregates are skipped
    /// (their sub-devices are muted directly).
    nonisolated static func inputDevices() -> [AudioDevice] {
        AudioDevices.all().filter { $0.inputChannels > 0 && $0.transportType != kAudioDeviceTransportTypeAggregate }
    }

    nonisolated static func capabilities(_ d: AudioDevice) -> MuteCapabilities {
        MuteCapabilities(
            muteSettable: settable(d.id, kAudioDevicePropertyMute, 0),
            masterVolumeSettable: settable(d.id, kAudioDevicePropertyVolumeScalar, 0),
            channelVolumeSettable: (0..<UInt32(d.inputChannels)).map { $0 + 1 }
                .filter { settable(d.id, kAudioDevicePropertyVolumeScalar, $0) })
    }

    nonisolated static func muteValue(_ id: AudioObjectID) -> UInt32? {
        var addr = address(kAudioDevicePropertyMute, 0)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    nonisolated static func volumes(_ d: AudioDevice) -> [UInt32: Float] {
        volumes(id: d.id, elements: [0] + (0..<UInt32(d.inputChannels)).map { $0 + 1 })
    }

    nonisolated static func volumes(id: AudioObjectID, elements: [UInt32]) -> [UInt32: Float] {
        var out: [UInt32: Float] = [:]
        for e in elements {
            var addr = address(kAudioDevicePropertyVolumeScalar, e)
            guard AudioObjectHasProperty(id, &addr) else { continue }
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr { out[e] = v }
        }
        return out
    }

    nonisolated static func address(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
    }

    nonisolated static func settable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32) -> Bool {
        var addr = address(selector, element)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
    }

    @discardableResult
    nonisolated static func setUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: UInt32) -> Bool {
        var addr = address(selector, element)
        var v = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    @discardableResult
    nonisolated static func setFloat(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: Float) -> Bool {
        var addr = address(selector, element)
        var v = Float32(value)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
}
