import KaikuCore
import PartitiUI
import SwiftUI

/// Lines of the live transcript: who is talking, then the text. Text the engine may
/// still change is dimmed.
struct LiveLines: View {
    let lines: [LiveLine]
    /// Lines per entry before the text is cut; nil shows everything.
    var lineLimit: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        VStack(alignment: .leading, spacing: PUI.Space.s) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: PUI.Space.m) {
                    Text(line.speaker.label)
                        .font(PUI.Font.label)
                        .foregroundStyle(line.speaker == .me ? AppAccent.kaiku.legible(scheme) : ink.secondary)
                        .frame(width: 34, alignment: .leading)
                    Text(line.text)
                        .font(PUI.Font.callout)
                        .foregroundStyle(line.isFinal ? ink.primary : ink.secondary)
                        .lineLimit(lineLimit)
                        // A line still being spoken keeps its newest words in view.
                        .truncationMode(line.isFinal ? .tail : .head)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The last few lines of the live transcript, as a section of the popover.
struct LiveCard: View {
    @ObservedObject var live: LiveSession
    @Environment(\.colorScheme) private var scheme

    private static let shownLines = 4

    var body: some View {
        if live.isVisible {
            Card {
                VStack(alignment: .leading, spacing: PUI.Space.m) {
                    SectionHeader("Live transcript")
                    if live.transcript.isEmpty {
                        Text("Listening…").font(PUI.Font.callout).foregroundStyle(Ink(scheme).tertiary)
                    } else {
                        LiveLines(lines: live.transcript.lastLines(Self.shownLines), lineLimit: 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// In the recording card: why the live transcription stopped. The recording goes on.
struct LiveNotice: View {
    @ObservedObject var live: LiveSession

    var body: some View {
        if let notice = live.notice {
            Inked { ink in
                HStack(alignment: .firstTextBaseline, spacing: PUI.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ink.orange)
                    Text("\(notice) Still recording; the call is transcribed when it ends.")
                        .foregroundStyle(ink.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(PUI.Font.caption)
            }
            .help(notice)
        }
    }
}
