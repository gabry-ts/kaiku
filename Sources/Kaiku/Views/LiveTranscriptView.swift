import KaikuCore
import PartitiUI
import SwiftUI

/// Lines of the live transcript: who is talking, then the text. Text the engine may
/// still change is dimmed.
struct LiveLines: View {
    let lines: [LiveLine]
    /// Lines per entry before the text is cut; nil shows everything.
    var lineLimit: Int?
    /// The reading size: callout in the popover, body in the floating window.
    var font: Font = PUI.Font.callout
    /// Shows when each line started, under the speaker.
    var showsTime = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        VStack(alignment: .leading, spacing: showsTime ? PUI.Space.l : PUI.Space.s) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: PUI.Space.m) {
                    VStack(alignment: .leading, spacing: PUI.Space.xxs) {
                        Text(line.speaker.label)
                            .font(showsTime ? PUI.Font.label.weight(.semibold) : PUI.Font.label)
                            .foregroundStyle(line.speaker == .me ? AppAccent.kaiku.legible(scheme) : ink.secondary)
                        if showsTime {
                            Text(Self.time(line.start))
                                .font(PUI.Font.caption.monospacedDigit())
                                .foregroundStyle(ink.tertiary)
                        }
                    }
                    .frame(width: showsTime ? 40 : 34, alignment: .leading)
                    Text(line.text)
                        .font(font)
                        .lineSpacing(showsTime ? 2 : 0)
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

    /// Minutes and seconds into the recording, with hours only once there are any.
    static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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
        GeometryReader { geo in
            VStack(spacing: 0) {
                // The header fills the clear title bar, level with the close button.
                header
                    .frame(maxWidth: .infinity)
                    .frame(height: max(geo.safeAreaInsets.top, PUI.Control.large))
                Hairline()
                switch assistant.isEnabled ? tab : .transcript {
                case .transcript: transcript
                case .summary: LiveSummaryTab(assistant: assistant)
                case .ask: LiveAskTab(assistant: assistant)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: Self.minSize.width, maxWidth: .infinity, minHeight: Self.minSize.height, maxHeight: .infinity)
        .background { LiveWindowMaterial().ignoresSafeArea() }
        .puiAccent(.kaiku)
    }

    @ViewBuilder private var header: some View {
        if assistant.isEnabled {
            SegmentedPill([(value: Tab.transcript, title: "Transcript"), (value: Tab.summary, title: "Summary"),
                           (value: Tab.ask, title: "Ask")], selection: $tab)
        } else {
            Text("Live Transcript")
                .font(PUI.Font.label)
                .foregroundStyle(Ink(scheme).secondary)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PUI.Space.l) {
                    if live.transcript.isEmpty {
                        LiveEmptyState(symbol: live.isRunning ? "waveform" : "captions.bubble",
                                       text: live.isRunning ? "Listening…" : "Nothing to show. The live transcript follows the call while you record.")
                    } else {
                        LiveLines(lines: live.transcript.lines, font: PUI.Font.body, showsTime: true)
                    }
                    LiveNotice(live: live)
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(.horizontal, PUI.Space.xl)
                .padding(.vertical, PUI.Space.l)
            }
            .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: live.transcript) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }
}

/// What a tab of the live window shows before it has anything: a symbol over a short line.
struct LiveEmptyState<Accessory: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var accessory: Accessory
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        VStack(spacing: PUI.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(ink.tertiary)
            Text(text)
                .font(PUI.Font.callout)
                .foregroundStyle(ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            accessory
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
        .padding(.vertical, PUI.Space.xxl * 2)
    }
}

extension LiveEmptyState where Accessory == EmptyView {
    init(symbol: String, text: String) {
        self.init(symbol: symbol, text: text) { EmptyView() }
    }
}

/// The floating window's backdrop: the system's translucent popover material, so the
/// window reads as a light utility panel over whatever is behind it.
struct LiveWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
