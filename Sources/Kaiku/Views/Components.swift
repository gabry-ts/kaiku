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

/// A scrolling settings pane that opens with Partiti UI's header for `pane`.
struct KaikuPane<Content: View>: View {
    let pane: SettingsPane
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            PartitiUI.SettingsPane {
                PaneHeader(Text(pane.title), subtitle: Text(subtitle), symbol: pane.symbol, color: pane.tint)
            } content: {
                content
            }
        }
        .scrollBounceBehavior(.basedOnSize)
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
