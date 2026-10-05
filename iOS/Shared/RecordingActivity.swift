import ActivityKit
import Foundation

/// What the Live Activity and the Dynamic Island show while a recording runs.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        /// When the recording was paused; nil while it runs.
        var pausedAt: Date?
        /// Seconds spent paused before `pausedAt`.
        var pausedTotal: Double
        var bookmarks: Int

        /// Start of the timer: the real start moved forward by the time spent paused.
        var timerStart: Date { startedAt.addingTimeInterval(pausedTotal) }
    }

    var title: String
}
