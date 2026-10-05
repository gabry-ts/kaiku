import ActivityKit
import Foundation

/// Keeps the recording's Live Activity in step with the recorder.
@MainActor
final class RecordingActivityController {
    private var activity: Activity<RecordingActivityAttributes>?
    private var state = RecordingActivityAttributes.ContentState(startedAt: .now, pausedAt: nil, pausedTotal: 0, bookmarks: 0)

    func start(title: String, at date: Date) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        state = .init(startedAt: date, pausedAt: nil, pausedTotal: 0, bookmarks: 0)
        activity = try? Activity.request(
            attributes: RecordingActivityAttributes(title: title),
            content: ActivityContent(state: state, staleDate: nil))
    }

    func pause(at date: Date = .now) {
        state.pausedAt = date
        push()
    }

    func resume(at date: Date = .now) {
        if let pausedAt = state.pausedAt { state.pausedTotal += date.timeIntervalSince(pausedAt) }
        state.pausedAt = nil
        push()
    }

    func setBookmarks(_ count: Int) {
        state.bookmarks = count
        push()
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func push() {
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }
}
