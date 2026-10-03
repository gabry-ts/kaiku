import PartitiUI
import SwiftUI

/// A row of a settings pane to scroll to and highlight, from a link, a search result or a problem.
struct SettingsTarget: Equatable {
    let pane: SettingsPane
    /// The `settingsAnchor` of the row or group; nil shows the top of the pane.
    let anchor: String?
    /// Every request is new, so asking twice for the same row scrolls again.
    let id = UUID()

    init(_ pane: SettingsPane, _ anchor: String? = nil) {
        self.pane = pane
        self.anchor = anchor
    }
}

/// What the main window shows: the calls or the chat, or Settings with its pane and the row
/// a pane should scroll to when it appears.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()

    /// Settings replace the calls in the sidebar and the detail column.
    @Published var showingSettings = false
    /// The calls or the chat, shown when Settings aren't.
    @Published var mode = LibraryDetailMode.call
    @Published var pane: SettingsPane = .general
    /// The row waiting for its pane to scroll to it.
    @Published var request: SettingsTarget?
    /// The row shown with a highlight, for a moment after jumping to it.
    @Published private(set) var highlighted: String?
    private var fade: Task<Void, Never>?

    /// Shows `pane`, or the last one, scrolled to `anchor`.
    func open(_ pane: SettingsPane?, anchor: String? = nil) {
        let pane = pane ?? self.pane
        self.pane = pane
        request = anchor.map { SettingsTarget(pane, $0) }
    }

    /// Back to the calls, as they were left.
    func closeSettings() {
        showingSettings = false
        request = nil
    }

    /// True when a pane should open the disclosure or expandable row holding one of `anchors`.
    func wants(_ anchors: Set<String>, in pane: SettingsPane) -> Bool {
        guard let request, request.pane == pane, let anchor = request.anchor else { return false }
        return anchors.contains(anchor)
    }

    /// Called by the pane once it scrolled to the requested row.
    func reached(_ target: SettingsTarget) {
        guard request == target else { return }
        request = nil
        highlighted = target.anchor
        fade?.cancel()
        fade = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            highlighted = nil
        }
    }
}

extension View {
    /// Marks a settings row or group as a place links and search results can jump to.
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchorModifier(id: id))
    }
}

private struct SettingsAnchorModifier: ViewModifier {
    let id: String
    @ObservedObject private var nav = AppNavigation.shared
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let on = nav.highlighted == id
        let shape = RoundedRectangle(cornerRadius: PUI.Radius.row, style: .continuous)
        content
            .background {
                if on { shape.fill(AppAccent.kaiku.color.opacity(0.14)) }
            }
            .overlay {
                if on { shape.strokeBorder(AppAccent.kaiku.color.opacity(0.6), lineWidth: 1) }
            }
            .id(id)
    }
}
