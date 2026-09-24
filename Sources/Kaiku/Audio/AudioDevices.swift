import CoreAudio
import Foundation

/// A Core Audio device, as needed for picking the microphone and for diagnostics.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
    let inputChannels: Int
    let outputChannels: Int

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }

    var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default: return fourCC(Int(transportType)).trimmingCharacters(in: CharacterSet(charactersIn: " '"))
        }
    }

    var nominalSampleRate: Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    /// True while any process is doing IO on this device.
    var isRunningSomewhere: Bool {
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running)
        return running != 0
    }

    var isAlive: Bool {
        var alive = UInt32(1)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive)
        return alive != 0
    }

    /// Output data source, e.g. 'ispk' (internal speakers) or 'hdpn' (headphone jack).
    var outputDataSource: UInt32? {
        var source = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &source) == noErr else { return nil }
        return source
    }

    /// Whether sound from this output stays in the user's ears (so the mic doesn't pick it up).
    /// Bluetooth and USB count as headphones; built-in speakers, HDMI, DisplayPort and AirPlay don't.
    var isHeadphones: Bool {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return outputDataSource == 0x6864_706E // 'hdpn'
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return false
        default:
            return true
        }
    }

    var summary: String {
        "\(name) [\(transportName), \(Int(nominalSampleRate)) Hz, in \(inputChannels) ch, out \(outputChannels) ch, running: \(isRunningSomewhere)]"
    }
}

enum AudioDevices {
    /// Settings value for the microphone picker.
    static let automatic = "auto"
    static let none = "none"

    static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device)
    }

    static func inputs() -> [AudioDevice] {
        all().filter { $0.inputChannels > 0 && $0.transportType != kAudioDeviceTransportTypeAggregate }
    }

    static var defaultInput: AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    static var defaultOutput: AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    /// Resolves the microphone setting to a device. Never returns a Bluetooth device in
    /// automatic mode: opening a Bluetooth headset mic switches it to the low quality
    /// call profile, which degrades the call for everyone.
    static func resolveMicrophone(setting: String) -> AudioDevice? {
        let inputs = inputs()
        switch setting {
        case none:
            return nil
        case automatic, "":
            if let def = defaultInput, !def.isBluetooth { return def }
            return inputs.first(where: \.isBuiltIn) ?? inputs.first { !$0.isBluetooth }
        default:
            return inputs.first { $0.uid == setting } ?? resolveMicrophone(setting: automatic)
        }
    }

    /// A microphone to switch to when `lostUID` disappears mid-call. Same rules as Automatic:
    /// never a Bluetooth headset.
    static func fallbackMicrophone(excluding lostUID: String?) -> AudioDevice? {
        let inputs = inputs().filter { $0.uid != lostUID && !$0.isBluetooth && $0.isAlive }
        if let def = defaultInput, def.uid != lostUID, !def.isBluetooth, inputs.contains(def) { return def }
        return inputs.first(where: \.isBuiltIn) ?? inputs.first
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDevice? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return device(id)
    }

    private static func device(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        return AudioDevice(
            id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, transportType: transport,
            inputChannels: channels(id, kAudioObjectPropertyScopeInput),
            outputChannels: channels(id, kAudioObjectPropertyScopeOutput))
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
