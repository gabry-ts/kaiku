import AppKit
import PartitiUI
import SwiftUI

/// The small floating panel shown while dictating, near the bottom center of the screen.
/// It never becomes key or active, so the app being typed in keeps the focus.
@MainActor
final class DictationHUD {
    static let shared = DictationHUD()

    static let size = NSSize(width: 360, height: 52)
    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = NSHostingView(rootView: DictationHUDView(controller: .shared).withoutAnimations())
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        return panel
    }

    /// Bottom center of the screen the pointer is on.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: (frame.midX - Self.size.width / 2).rounded(), y: frame.minY + 72))
    }
}

struct DictationHUDView: View {
    @ObservedObject var controller: DictationController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        HStack(spacing: PUI.Space.m) {
            icon(ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(status).font(PUI.Font.body.weight(.medium)).foregroundStyle(ink.primary).lineLimit(1)
                Text(detail).font(PUI.Font.caption).foregroundStyle(ink.secondary).lineLimit(1)
            }
            Spacer(minLength: PUI.Space.s)
            if controller.phase == .recording {
                LevelMeter(level: controller.level, segments: 12)
            } else if controller.isBusy {
                ProgressView().controlSize(.small)
            }
            if let mode = controller.modeName, controller.phase == .recording || controller.isBusy {
                Button(mode) { controller.cycleMode() }
                    .buttonStyle(.plain)
                    .font(PUI.Font.caption.weight(.medium))
                    .padding(.horizontal, PUI.Space.s)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(ink.strongFill))
                    .help("Switch mode")
            }
        }
        .padding(.horizontal, PUI.Space.l)
        .frame(width: DictationHUD.size.width, height: DictationHUD.size.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder private func icon(_ ink: Ink) -> some View {
        switch controller.phase {
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ink.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(ink.green)
        case .recording:
            Image(systemName: "mic.fill").foregroundStyle(AppAccent.kaiku.color)
        default:
            Image(systemName: "waveform").foregroundStyle(ink.secondary)
        }
    }

    private var status: String {
        switch controller.phase {
        case .idle, .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .polishing: return "Polishing…"
        case .done(let text), .failed(let text): return text
        }
    }

    private var detail: String {
        switch controller.phase {
        case .done, .failed: return "Dictation"
        default: return "\(controller.providerName) · Esc to cancel"
        }
    }
}
