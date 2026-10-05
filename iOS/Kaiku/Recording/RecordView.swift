import SwiftUI
import KaikuCore

struct RecordView: View {
    @Environment(MeetingRecorder.self) private var recorder

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(clock(recorder.elapsed))
                        .font(.system(size: 56, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(recorder.state == .idle ? .secondary : .primary)
                }
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 40) {
                    sideButton("Bookmark", systemImage: "bookmark.fill") { recorder.addBookmark() }
                        .disabled(recorder.state == .idle)
                    recordButton
                    sideButton(recorder.state == .paused ? "Resume" : "Pause",
                               systemImage: recorder.state == .paused ? "play.fill" : "pause.fill") {
                        if recorder.state == .paused { recorder.resume() } else { recorder.pause() }
                    }
                    .disabled(recorder.state == .idle)
                }

                if let error = recorder.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                if !recorder.bookmarks.isEmpty {
                    Text(recorder.bookmarks.map { clock($0.time) }.joined(separator: "  "))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationTitle("Record")
        }
    }

    private var status: String {
        if recorder.isFinishing { return "Saving…" }
        switch recorder.state {
        case .idle: return "Ready to record"
        case .recording: return "Recording"
        case .paused: return "Paused"
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                if recorder.state == .idle { await recorder.start() } else { await recorder.stop() }
            }
        } label: {
            ZStack {
                Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 4).frame(width: 88, height: 88)
                if recorder.state == .idle {
                    Circle().fill(Color.accentColor).frame(width: 70, height: 70)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor).frame(width: 34, height: 34)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.isFinishing)
        .accessibilityLabel(recorder.state == .idle ? "Start recording" : "Stop recording")
    }

    private func sideButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title2).frame(width: 52, height: 52)
                    .background(.fill.tertiary, in: Circle())
                Text(title).font(.caption)
            }
        }
        .buttonStyle(.plain)
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
