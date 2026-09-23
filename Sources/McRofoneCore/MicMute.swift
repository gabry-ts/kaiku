import Foundation

/// A span of the recording (recorded seconds) during which all microphones were muted.
public struct MuteInterval: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double?
    public init(start: Double, end: Double? = nil) {
        self.start = start
        self.end = end
    }
}

/// What an input device lets us change.
public struct MuteCapabilities: Equatable, Sendable {
    public var muteSettable: Bool
    public var masterVolumeSettable: Bool
    /// Input channel elements (1...n) whose volume is settable.
    public var channelVolumeSettable: [UInt32]

    public init(muteSettable: Bool, masterVolumeSettable: Bool, channelVolumeSettable: [UInt32]) {
        self.muteSettable = muteSettable
        self.masterVolumeSettable = masterVolumeSettable
        self.channelVolumeSettable = channelVolumeSettable
    }
}

/// How a device is silenced.
public enum MuteMethod: Equatable, Sendable {
    case mute
    /// Volume set to 0 on these elements (0 = master).
    case volume(elements: [UInt32])
    case unsupported
}

/// The state of one input device before it was muted, restored on unmute.
public struct MicDeviceState: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var mute: UInt32?
    /// Volume scalar by element ("0" = master, "1"... = channels).
    public var volumes: [String: Float]

    public init(uid: String, name: String, mute: UInt32?, volumes: [String: Float]) {
        self.uid = uid
        self.name = name
        self.mute = mute
        self.volumes = volumes
    }
}

public enum MutePlanner {
    /// Prefer the mute switch; else master volume; else every settable channel.
    public static func method(_ caps: MuteCapabilities) -> MuteMethod {
        if caps.muteSettable { return .mute }
        if caps.masterVolumeSettable { return .volume(elements: [0]) }
        if !caps.channelVolumeSettable.isEmpty { return .volume(elements: caps.channelVolumeSettable.sorted()) }
        return .unsupported
    }

    /// True when something (an app's automatic gain control) undid our mute.
    public static func needsReapply(_ method: MuteMethod, mute: UInt32?, volumes: [UInt32: Float]) -> Bool {
        switch method {
        case .mute: return mute != 1
        case .volume(let elements): return elements.contains { (volumes[$0] ?? 1) > 0.0001 }
        case .unsupported: return false
        }
    }

    /// The next thing to try when the mute switch doesn't stick (some virtual devices
    /// accept the write but ignore it).
    public static func fallback(_ caps: MuteCapabilities) -> MuteMethod {
        var c = caps
        c.muteSettable = false
        return method(c)
    }

    /// Saves everything we may change (mute switch and settable volumes), so a fallback
    /// from mute to volume is still restored exactly.
    public static func stateToSave(uid: String, name: String, caps: MuteCapabilities,
                                   mute: UInt32?, volumes: [UInt32: Float]) -> MicDeviceState {
        var saved: [String: Float] = [:]
        let elements = (caps.masterVolumeSettable ? [0] : []) + caps.channelVolumeSettable
        for e in elements { if let v = volumes[e] { saved[String(e)] = v } }
        return MicDeviceState(uid: uid, name: name, mute: caps.muteSettable ? (mute ?? 0) : nil, volumes: saved)
    }

    /// Adds devices not saved yet, keeping the first saved state of each (the real "before").
    public static func merge(_ saved: [MicDeviceState], adding new: [MicDeviceState]) -> [MicDeviceState] {
        var out = saved
        for s in new where !out.contains(where: { $0.uid == s.uid }) { out.append(s) }
        return out
    }
}
