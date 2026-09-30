import Foundation

/// What the user wants to happen when the call being recorded ends.
public enum CallEndMode: String, CaseIterable, Identifiable, Sendable {
    /// Stop the recording after the chosen delay, with a notification that can stop it sooner.
    case stopAfterDelay
    /// Ask with a notification and keep recording until it is answered.
    case ask
    /// Keep recording, without a notification.
    case nothing

    public static let standard = CallEndMode.stopAfterDelay

    public var id: String { rawValue }

    /// The saved mode, or the standard one when nothing (or something unknown) was saved.
    public init(saved: String?) {
        self = saved.flatMap(CallEndMode.init(rawValue:)) ?? .standard
    }

    public var title: String {
        switch self {
        case .stopAfterDelay: return "Stop after a delay"
        case .ask: return "Ask every time"
        case .nothing: return "Do nothing"
        }
    }

    /// What really happens. Asking needs the "call ended" notification: when macOS doesn't
    /// allow notifications, or that one is switched off, the question would never be seen
    /// and the recording would never end, so the delay applies instead.
    public func behavior(notificationsAllowed: Bool, callEndedNotificationEnabled: Bool) -> CallEndBehavior {
        switch self {
        case .stopAfterDelay: return .stopAfterDelay
        case .ask: return notificationsAllowed && callEndedNotificationEnabled ? .ask : .stopAfterDelay
        case .nothing: return .nothing
        }
    }
}

/// What happens when a call ends, once the mode is checked against what can be shown.
public enum CallEndBehavior: Equatable, Sendable {
    /// Notify, then stop after the delay unless the call resumes.
    case stopAfterDelay
    /// Notify with Stop Recording / Keep Recording and never stop by itself.
    case ask
    /// No notification, no automatic stop.
    case nothing

    /// Seconds after which the recording stops by itself; 0 is never.
    public func autoStopSeconds(delay: Int) -> Int {
        self == .stopAfterDelay ? max(0, delay) : 0
    }

    public var notifies: Bool { self != .nothing }
}
