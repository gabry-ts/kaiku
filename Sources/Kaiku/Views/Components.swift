import PartitiUI
import SwiftUI

extension AppIconView {
    /// The app icon as an image, for Partiti UI pieces that take one (popover header, About).
    @MainActor static let image: Image = {
        let renderer = ImageRenderer(content: AppIconView().frame(width: 256, height: 256))
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return Image(systemName: "mic.fill") }
        return Image(decorative: cgImage, scale: 1)
    }()
}

/// A level meter made of rounded segments, 0...1: green, orange near the top.
struct LevelMeter: View {
    var level: Float
    var segments = 22
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        let value = Double(min(max(level, 0), 1))
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let position = Double(i) / Double(segments)
                Capsule()
                    .fill(position < value ? (position > 0.8 ? ink.orange : ink.green) : ink.strongFill)
                    .frame(width: 4, height: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// A small colored symbol and a line of text, for status in settings rows.
struct StatusDot: View {
    enum Kind { case ok, warning, error, neutral }
    let kind: Kind
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        HStack(alignment: .firstTextBaseline, spacing: PUI.Space.xs + 1) {
            Image(systemName: symbol).foregroundStyle(color(ink))
            Text(text).foregroundStyle(ink.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(PUI.Font.callout)
    }

    private var symbol: String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .neutral: return "circle.dashed"
        }
    }

    private func color(_ ink: Ink) -> Color {
        switch kind {
        case .ok: return ink.green
        case .warning: return ink.orange
        case .error: return ink.red
        case .neutral: return ink.tertiary
        }
    }
}

// MARK: - Settings

/// A scrolling settings pane that opens with Partiti UI's header for `pane`. It scrolls to
/// the row a link or a search result asked for, which then shows a highlight for a moment.
/// The form keeps a readable width on the left, however wide the window.
struct KaikuPane<Content: View>: View {
    let pane: SettingsPane
    let subtitle: String
    @ViewBuilder let content: Content
    @ObservedObject private var nav = AppNavigation.shared

    /// Widest the form grows, and its minimum side margin.
    static var maxWidth: CGFloat { 900 }
    static var margin: CGFloat { 40 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PUI.Space.xl + 2) {
                    PaneHeader(Text(pane.title), subtitle: Text(subtitle), symbol: pane.symbol, color: pane.tint)
                        .id(Self.top)
                    content
                }
                .frame(maxWidth: Self.maxWidth, alignment: .leading)
                .padding(.horizontal, Self.margin)
                .padding(.top, PUI.Space.xxl + PUI.Space.xs)
                .padding(.bottom, PUI.Space.xxl)
                // Centered in the window, like the transcript's reading column.
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { jump(proxy) }
            .onChange(of: nav.request) { _, _ in jump(proxy) }
            .onChange(of: nav.pane) { _, _ in proxy.scrollTo(Self.top, anchor: .top) }
        }
    }

    private static var top: String { "pane-top" }

    /// Scrolls to the requested row once disclosures it lives in had a turn to open.
    private func jump(_ proxy: ScrollViewProxy) {
        guard let request = nav.request, request.pane == pane, let anchor = request.anchor else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(anchor, anchor: .center)
            nav.reached(request)
        }
    }
}

/// A row of a `SettingsGroup` with free content, padded like `SettingsRow`.
struct GroupRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, PUI.Space.l)
            .padding(.vertical, PUI.Space.m)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
}

/// A multi-line text editor drawn like a Partiti UI field.
struct EditorField: View {
    @Binding var text: String
    var minHeight: CGFloat = 130
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: minHeight)
            .scrollContentBackground(.hidden)
            .padding(PUI.Space.s)
            .background {
                ZStack {
                    shape.fill(scheme == .dark ? Color.white.opacity(0.06) : Color.white)
                    shape.strokeBorder(Color.black.opacity(scheme == .dark ? 0.3 : 0.12), lineWidth: 0.5)
                }
            }
    }
}
