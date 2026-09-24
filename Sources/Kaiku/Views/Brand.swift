import AppKit
import SwiftUI

/// Brand colors and small shared visual pieces.
enum Brand {
    /// Warm coral red. Used sparingly: primary actions and the recording state.
    static let accent = Color(red: 0.949, green: 0.341, blue: 0.294)
    static let nsAccent = NSColor(red: 0.949, green: 0.341, blue: 0.294, alpha: 1)

    private static let speakerPalette: [Color] = [.teal, .indigo, .orange, .green, .purple, .pink, .blue, .brown]

    /// Stable color per speaker name. The microphone speaker gets the accent.
    static func color(forSpeaker name: String, me: String = AppSettings.meLabel) -> Color {
        if name == me { return accent }
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return speakerPalette[hash % speakerPalette.count]
    }

    /// Distinct colors for the speakers of one transcript, in order of appearance.
    static func speakerColors(_ speakers: [String], me: String = AppSettings.meLabel) -> [String: Color] {
        var map: [String: Color] = [:]
        var next = 0
        for s in speakers where map[s] == nil {
            if s == me { map[s] = accent } else {
                map[s] = speakerPalette[next % speakerPalette.count]
                next += 1
            }
        }
        return map
    }
}

// MARK: - App icon

/// The app icon, drawn in a 1024 × 1024 space following the macOS icon grid
/// (824 pt squircle body, room for the drop shadow).
struct AppIconView: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 1024
            ctx.scaleBy(x: s, y: s)
            let body = CGRect(x: 100, y: 100, width: 824, height: 824)
            let squircle = Path(roundedRect: body, cornerRadius: 185, style: .continuous)

            // Drop shadow.
            var shadowCtx = ctx
            shadowCtx.addFilter(.shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 12))
            shadowCtx.fill(squircle, with: .color(Color(red: 0.86, green: 0.2, blue: 0.24)))

            // Body gradient: coral to deep red.
            ctx.fill(squircle, with: .linearGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.52, blue: 0.38), Color(red: 0.86, green: 0.19, blue: 0.27)]),
                startPoint: CGPoint(x: 512, y: 100), endPoint: CGPoint(x: 512, y: 924)))

            // Soft top sheen.
            ctx.fill(squircle, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.22), .white.opacity(0)]),
                startPoint: CGPoint(x: 512, y: 100), endPoint: CGPoint(x: 512, y: 520)))

            // Hairline inner edge.
            ctx.stroke(Path(roundedRect: body.insetBy(dx: 2, dy: 2), cornerRadius: 183, style: .continuous),
                       with: .color(.white.opacity(0.18)), lineWidth: 4)

            let white = Color.white
            // Waveform bars on both sides.
            let bars: [(dx: CGFloat, h: CGFloat)] = [(222, 210), (286, 140), (350, 80)]
            for bar in bars {
                for sign in [-1.0, 1.0] {
                    let x = 512 + sign * bar.dx
                    let rect = CGRect(x: x - 17, y: 470 - bar.h / 2, width: 34, height: bar.h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 17), with: .color(white.opacity(bar.dx == 222 ? 0.92 : (bar.dx == 286 ? 0.72 : 0.5))))
                }
            }

            // Microphone stand: U arc, stem, base.
            var stand = Path()
            stand.addArc(center: CGPoint(x: 512, y: 460), radius: 148,
                         startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            stand.move(to: CGPoint(x: 512, y: 608))
            stand.addLine(to: CGPoint(x: 512, y: 706))
            stand.move(to: CGPoint(x: 420, y: 716))
            stand.addLine(to: CGPoint(x: 604, y: 716))
            var standCtx = ctx
            standCtx.addFilter(.shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 6))
            standCtx.stroke(stand, with: .color(white), style: StrokeStyle(lineWidth: 36, lineCap: .round))

            // Microphone capsule with depth.
            let capsule = CGRect(x: 412, y: 238, width: 200, height: 340)
            let capsulePath = Path(roundedRect: capsule, cornerRadius: 100, style: .continuous)
            var capCtx = ctx
            capCtx.addFilter(.shadow(color: Color(red: 0.45, green: 0.05, blue: 0.1).opacity(0.35), radius: 18, x: 0, y: 14))
            capCtx.fill(capsulePath, with: .color(white))
            ctx.fill(capsulePath, with: .linearGradient(
                Gradient(colors: [.white, Color(red: 1.0, green: 0.9, blue: 0.87)]),
                startPoint: CGPoint(x: 430, y: 238), endPoint: CGPoint(x: 600, y: 578)))

            // Grille slots.
            for i in 0..<3 {
                let y = 318 + CGFloat(i) * 46
                let slot = CGRect(x: 474, y: y, width: 76, height: 16)
                ctx.fill(Path(roundedRect: slot, cornerRadius: 8),
                         with: .color(Color(red: 0.86, green: 0.25, blue: 0.27).opacity(0.28)))
            }
            // Specular highlight on the capsule.
            let spec = CGRect(x: 434, y: 276, width: 24, height: 120)
            ctx.fill(Path(roundedRect: spec, cornerRadius: 12), with: .linearGradient(
                Gradient(colors: [.white, .white.opacity(0)]),
                startPoint: CGPoint(x: 446, y: 276), endPoint: CGPoint(x: 446, y: 396)))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Menu bar glyphs

enum MenuBarGlyph {
    /// Template glyph: microphone flanked by level bars. `frame` animates the bars.
    static func idle(frame: Int? = nil) -> NSImage {
        let heights: [[CGFloat]] = [[7, 4], [4, 7], [9, 5], [5, 3]]
        let h = frame.map { heights[$0 % heights.count] } ?? [7, 4]
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            // Capsule.
            NSBezierPath(roundedRect: NSRect(x: 8.25, y: 7, width: 5.5, height: 9), xRadius: 2.75, yRadius: 2.75).fill()
            // Stand.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 11, y: 10), radius: 4.6, startAngle: 180, endAngle: 360, clockwise: false)
            arc.move(to: NSPoint(x: 11, y: 5.4))
            arc.line(to: NSPoint(x: 11, y: 2.6))
            arc.move(to: NSPoint(x: 8.4, y: 2.2))
            arc.line(to: NSPoint(x: 13.6, y: 2.2))
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            arc.stroke()
            // Bars.
            for (i, dx) in [CGFloat(7.4), 10.2].enumerated() {
                for sign in [-1.0, 1.0] as [CGFloat] {
                    let x = 11 + sign * dx
                    let bh = h[i]
                    NSBezierPath(roundedRect: NSRect(x: x - 0.8, y: 10 - bh / 2, width: 1.6, height: bh),
                                 xRadius: 0.8, yRadius: 0.8).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kaiku"
        return image
    }

    /// Non-template red pill with a white dot and the elapsed time; a crossed-out mic
    /// at the end when all microphones are muted.
    static func recording(elapsed: String, muted: Bool = false) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (elapsed as NSString).size(withAttributes: attrs)
        let width = ceil(textSize.width) + 24 + (muted ? 14 : 0)
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
            let pill = NSRect(x: 0, y: 1, width: rect.width, height: 16)
            Brand.nsAccent.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 6, height: 6)).fill()
            (elapsed as NSString).draw(at: NSPoint(x: 16, y: 9 - textSize.height / 2), withAttributes: attrs)
            if muted { drawMutedBadge(at: NSPoint(x: rect.width - 19, y: 3)) }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = muted ? "Recording, \(elapsed), microphones muted" : "Recording, \(elapsed)"
        return image
    }

    /// Template crossed-out microphone: all microphones are muted.
    static func muted() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphones muted")?
            .withSymbolConfiguration(config) ?? idle()
        image.isTemplate = true
        return image
    }

    private static func drawMutedBadge(at origin: NSPoint) {
        let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: origin.x + (13 - size.width) / 2, y: origin.y + (12 - size.height) / 2,
                               width: size.width, height: size.height))
    }

    /// The glyph for the current state.
    @MainActor
    static func current(_ state: AppState, muted: Bool) -> NSImage {
        switch state.phase {
        case .recording:
            let time = shortTime(state.elapsed)
            return state.isPaused ? paused(elapsed: time, muted: muted) : recording(elapsed: time, muted: muted)
        case .error:
            return muted ? self.muted() : error()
        default:
            return muted ? self.muted() : idle(frame: state.anyBusy ? state.glyphFrame : nil)
        }
    }

    static func shortTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Non-template gray pill with a pause symbol and the recorded time: clearly not recording.
    static func paused(elapsed: String, muted: Bool = false) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (elapsed as NSString).size(withAttributes: attrs)
        let width = ceil(textSize.width) + 24 + (muted ? 14 : 0)
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
            let pill = NSRect(x: 0, y: 1, width: rect.width, height: 16)
            NSColor(white: 0.45, alpha: 1).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 5, width: 2.2, height: 8), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: 9.8, y: 5, width: 2.2, height: 8), xRadius: 1, yRadius: 1).fill()
            (elapsed as NSString).draw(at: NSPoint(x: 16, y: 9 - textSize.height / 2), withAttributes: attrs)
            if muted { drawMutedBadge(at: NSPoint(x: rect.width - 19, y: 3)) }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Recording paused, \(elapsed)"
        return image
    }

    static func error() -> NSImage {
        let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Kaiku error")
            ?? idle()
        image.isTemplate = true
        return image
    }
}

// MARK: - Shared small views

/// Filled accent button used for the one primary action on a screen. Looks the
/// same in key and non-key windows (the menu bar panel is often non-key).
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Brand.accent
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 14 : 12)
            .padding(.vertical, large ? 9 : 5)
            .background(
                RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous)
                    .fill(tint.gradient)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .overlay(RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: tint.opacity(0.25), radius: configuration.isPressed ? 1 : 3, y: 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(large: true) }
}

/// Horizontal level meter, 0...1.
struct LevelMeter: View {
    var level: Float
    var tint: Color = .green

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

/// Small colored dot + label, used for status.
struct StatusDot: View {
    enum Kind { case ok, warning, error, neutral }
    let kind: Kind
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
    }

    private var symbol: String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .neutral: return "circle.dashed"
        }
    }

    private var color: Color {
        switch kind {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        case .neutral: return .secondary
        }
    }
}

/// Rounded "card" background used for grouped content outside of Forms.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
