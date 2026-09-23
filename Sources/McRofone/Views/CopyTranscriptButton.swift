import SwiftUI

/// One-click copy of the full transcript (speaker names applied), with a short
/// "Copied" confirmation.
struct CopyTranscriptButton: View {
    let folder: RecordingFolder
    var labeled = true
    @State private var copied = false

    var body: some View {
        Button {
            copy(folder)
            withAnimation(.snappy) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            if labeled {
                Label(copied ? "Copied" : "Copy Transcript", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
        }
        .disabled(!folder.hasTranscript)
        .help(copied ? "Copied" : "Copy transcript")
        .accessibilityLabel(copied ? "Copied" : "Copy transcript")
    }
}
