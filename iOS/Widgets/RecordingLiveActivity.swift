import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(title: context.attributes.title, state: context.state)
                .padding()
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.title, systemImage: "mic.fill")
                        .font(.subheadline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTimer(state: state).font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Controls(state: state)
                }
            } compactLeading: {
                Image(systemName: state.pausedAt == nil ? "mic.fill" : "pause.fill").foregroundStyle(.red)
            } compactTrailing: {
                RecordingTimer(state: state).font(.caption.monospacedDigit()).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: state.pausedAt == nil ? "mic.fill" : "pause.fill").foregroundStyle(.red)
            }
        }
    }
}

private struct RecordingTimer: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Text(timerInterval: state.timerStart...Date.distantFuture, pauseTime: state.pausedAt, countsDown: false)
            .contentTransition(.identity)
            .multilineTextAlignment(.trailing)
    }
}

private struct Controls: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            if state.pausedAt == nil {
                Button(intent: PauseRecordingIntent()) { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
            } else {
                Button(intent: ResumeRecordingIntent()) { Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity) }
            }
            Button(intent: StopRecordingIntent()) { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                .tint(.red)
        }
        .buttonStyle(.bordered)
    }
}

private struct LockScreenView: View {
    let title: String
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: state.pausedAt == nil ? "mic.fill" : "pause.fill")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                RecordingTimer(state: state).font(.title2.monospacedDigit())
            }
            Controls(state: state)
        }
    }
}
