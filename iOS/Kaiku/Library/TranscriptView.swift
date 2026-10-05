import SwiftUI
import KaikuCore

/// The speaker turns of a call; tapping one plays the audio from there.
struct TranscriptView: View {
    let folder: RecordingFolder
    let meta: RecordingMeta
    let player: PlayerModel?

    private var turns: [Segment] {
        guard let raw = folder.loadSegments() else { return [] }
        return TranscriptWriter.displaySegments(meta: meta, rawSegments: raw)
    }

    var body: some View {
        let turns = turns
        List {
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                Button {
                    player?.seek(to: turn.start, play: true)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(turn.speaker ?? "Unknown").font(.subheadline.bold()).foregroundStyle(color(turn.speaker))
                            Spacer()
                            Text(TranscriptFormatter.timestamp(turn.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(turn.text).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if turns.isEmpty { ContentUnavailableView("No transcript", systemImage: "text.alignleft") }
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if let player { PlayerBar(player: player) } }
    }

    private static let palette: [Color] = [.teal, .indigo, .orange, .green, .purple, .pink, .blue, .brown]

    private func color(_ speaker: String?) -> Color {
        guard let speaker else { return .secondary }
        if speaker == PhoneSettings.meLabel { return .accentColor }
        let hash = speaker.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palette[hash % Self.palette.count]
    }
}
