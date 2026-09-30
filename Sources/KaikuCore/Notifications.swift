import Foundation

/// A notification Kaiku can post. Adding a case adds it to Settings > Notifications.
public enum NotificationKind: String, CaseIterable, Identifiable, Sendable {
    /// A call started and recording it needs an answer.
    case callDetected
    /// A recording started by itself for a source never seen before.
    case newSource
    /// A recording started by itself.
    case recordingStarted
    /// The call being recorded seems over.
    case callEnded
    /// A recording stopped by itself after the call ended.
    case recordingStopped
    case transcriptReady
    /// An interrupted recording was saved at launch.
    case recovered
    /// The microphone or the audio output changed while recording.
    case deviceChanged
    /// Something failed: a recording, a transcription, a summary, the webhook.
    case problem
    /// Automatic cleanup moved old audio to the Trash.
    case cleanup

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .callDetected: return "Call detected"
        case .newSource: return "New source"
        case .recordingStarted: return "Recording started"
        case .callEnded: return "Call ended"
        case .recordingStopped: return "Recording stopped"
        case .transcriptReady: return "Transcript ready"
        case .recovered: return "Recovered recording"
        case .deviceChanged: return "Audio device changed"
        case .problem: return "Problems"
        case .cleanup: return "Old audio cleaned up"
        }
    }

    /// When it appears.
    public var detail: String {
        switch self {
        case .callDetected: return "A call starts and Kaiku asks whether to record it."
        case .newSource: return "A recording started by itself for an app or website seen for the first time."
        case .recordingStarted: return "A recording started by itself for a call."
        case .callEnded: return "The call you are recording seems to be over."
        case .recordingStopped: return "A recording stopped by itself after the call ended."
        case .transcriptReady: return "A transcription finished."
        case .recovered: return "A recording interrupted by a crash or a restart was saved."
        case .deviceChanged: return "The microphone was disconnected or the call audio moved to another output, while recording."
        case .problem: return "A recording, transcription, summary or webhook failed."
        case .cleanup: return "Automatic cleanup moved old audio to the Trash."
        }
    }

    /// True when the notification carries a question: switched off, the app behaves
    /// as if it had been dismissed.
    public var asksQuestion: Bool {
        switch self {
        case .callDetected, .newSource, .callEnded, .recovered: return true
        default: return false
        }
    }

    /// UserDefaults key of the "show it" switch.
    public var showKey: String { "notify.\(rawValue).show" }
    /// UserDefaults key of the "play a sound" switch.
    public var soundKey: String { "notify.\(rawValue).sound" }

    /// Every notification plays a sound unless switched off.
    public var defaultSound: Bool { true }

    /// Whether it is shown when nothing was chosen yet. Before each notification had its
    /// own switch there were two: "notify me when a transcript is ready", which also
    /// covered the other informational ones, and "ask to stop when the call ends".
    /// Whatever they were set to carries over; the rest were always shown.
    /// - Parameters:
    ///   - legacyInformational: the saved "transcript is ready" switch, nil when never changed.
    ///   - legacyCallEnded: the saved "ask to stop" switch, nil when never changed.
    public func defaultShown(legacyInformational: Bool? = nil, legacyCallEnded: Bool? = nil) -> Bool {
        switch self {
        case .recordingStarted, .recordingStopped, .transcriptReady, .problem, .cleanup:
            return legacyInformational ?? true
        case .callEnded:
            return legacyCallEnded ?? true
        case .callDetected, .newSource, .recovered, .deviceChanged:
            return true
        }
    }
}
