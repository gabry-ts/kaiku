import AppKit
import Combine
import SwiftUI

/// The menu bar item. Click opens the panel (the same SwiftUI MenuPanel, in a transient
/// NSPopover: it closes on a second click on the icon, a click elsewhere, Esc, or when
/// you switch app or Space). Option-click mutes or unmutes all microphones without
/// opening anything.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    static let shared = StatusBarController()

    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    private var lastImageKey = ""
    /// When the popover last closed. A click on the icon closes a transient popover on
    /// mouse-down; the button action then fires on mouse-up and must not reopen it.
    private var lastClose = Date.distantPast

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("Kaiku")
        item.button?.toolTip = "Kaiku. Option-click to mute all microphones."
        self.item = item
        updateImage()
        // objectWillChange fires before the change: read the new values on the next turn.
        AppState.shared.objectWillChange
            .merge(with: MicMuter.shared.objectWillChange)
            .sink { _ in DispatchQueue.main.async { StatusBarController.shared.updateImage() } }
            .store(in: &cancellables)
    }

    private func updateImage() {
        guard let button = item?.button else { return }
        let state = AppState.shared
        let muted = MicMuter.shared.isMuted
        // Rebuild the image only when what it shows changes.
        let key = "\(state.phase)|\(state.isPaused)|\(MenuBarGlyph.shortTime(state.elapsed))|\(state.anyBusy ? state.glyphFrame : -1)|\(muted)"
        guard key != lastImageKey else { return }
        lastImageKey = key
        button.image = MenuBarGlyph.current(state, muted: muted)
    }

    @objc private func clicked(_ sender: Any?) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.option) {
            closePanel()
            MicMuter.shared.toggle()
            return
        }
        if popover?.isShown == true {
            closePanel()
        } else if Date().timeIntervalSince(lastClose) > 0.3 {
            showPanel()
        }
    }

    // MARK: Panel

    func showPanel() {
        guard let button = item?.button else { return }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        // A menu bar app must activate itself, or the popover never becomes key: no
        // keyboard shortcuts, no Esc, and no transient close.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func closePanel() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
        item?.button?.highlight(false)
    }

    private func makePopover() -> NSPopover {
        let hosting = NSHostingController(rootView: AnyView(
            MenuPanel()
                .environmentObject(AppState.shared)
                .defaultAppStorage(AppSettings.defaults)))
        hosting.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        return popover
    }
}
