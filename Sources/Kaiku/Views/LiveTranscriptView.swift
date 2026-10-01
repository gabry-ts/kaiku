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

/// The floating window: the whole live transcript, following the newest line, and the
/// Summary and Ask tabs when they are switched on.
struct LiveWindowView: View {
    enum Tab: String { case transcript, summary, ask }

    @ObservedObject var live: LiveSession
    @ObservedObject private var assistant: LiveAssistant
    @State private var tab: Tab
    @Environment(\.colorScheme) private var scheme

    static let size = CGSize(width: 400, height: 380)
    static let minSize = CGSize(width: 280, height: 160)
    private static let end = "end"

    init(live: LiveSession, tab: Tab = .transcript) {
        self.live = live
        _assistant = ObservedObject(wrappedValue: live.assistant)
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            if assistant.isEnabled {
                Picker("Show", selection: $tab) {
                    Text("Transcript").tag(Tab.transcript)
                    Text("Summary").tag(Tab.summary)
                    Text("Ask").tag(Tab.ask)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, PUI.Space.xl)
                .padding(.top, PUI.Space.l)
            }
            switch assistant.isEnabled ? tab : .transcript {
            case .transcript: transcript
            case .summary: LiveSummaryTab(assistant: assistant)
            case .ask: LiveAskTab(assistant: assistant)
            }
        }
        .frame(minWidth: Self.minSize.width, maxWidth: .infinity, minHeight: Self.minSize.height, maxHeight: .infinity)
        .puiAccent(.kaiku)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PUI.Space.l) {
                    if live.transcript.isEmpty {
                        Text(live.isRunning ? "Listening…" : "Nothing to show. The live transcript follows the call while you record.")
                            .font(PUI.Font.callout).foregroundStyle(Ink(scheme).tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LiveLines(lines: live.transcript.lines)
                    }
                    LiveNotice(live: live)
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(PUI.Space.xl)
            }
            .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: live.transcript) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }
}

/// In the recording card: opens the floating window, and says why the live
/// transcription stopped if it did. The recording goes on either way.
struct LiveControls: View {
    @ObservedObject var live: LiveSession

    var body: some View {
        if live.isVisible {
            Button { WindowManager.shared.showLiveTranscript() } label: {
                Label("Open Live Transcript", systemImage: "captions.bubble")
                    .labelStyle(TightLabelStyle(spacing: PUI.Space.s))
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            .help("Show the live transcript in a window that stays on top")
        }
        LiveNotice(live: live)
    }
}

/// Why the live transcription stopped.
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
