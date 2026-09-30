import AppKit
import KaikuCore
import PartitiUI
import SwiftUI

/// Opens AppKit windows hosting SwiftUI views. A menubar-only app has to
/// activate itself explicitly, otherwise windows open behind other apps.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var windows: [String: NSWindow] = [:]

    func showTitlePrompt(title: String, event: CalendarEventInfo?, call: DetectedCall? = nil) {
        let view = TitlePromptView(onDone: { [weak self] in self?.close("title") }, initialTitle: title, event: event, call: call)
            .environmentObject(AppState.shared)
            .defaultAppStorage(AppSettings.defaults)
        let panel = KeyPanel(contentRect: .zero,
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        Self.makeChromeless(panel, hideButtons: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        present(id: "title", window: panel, view: view, title: "New Recording", recreate: true)
    }

    func showSettings(_ pane: SettingsPane = .general) {
        let view = SettingsView(pane: pane).environmentObject(AppState.shared)
        // A full-size content view under a clear title bar, so Partiti UI's floating
        // sidebar runs under the traffic lights and each pane carries its own header.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: PUI.Window.settings),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = PUI.Window.settingsMin
        present(id: "settings", window: window, view: view, title: "Settings", recreate: false,
                size: PUI.Window.settings)
    }

    func showLibrary() {
        let view = LibraryView().environmentObject(AppState.shared).defaultAppStorage(AppSettings.defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("kaiku.library")
        present(id: "library", window: window, view: view, title: "Recordings", recreate: false, bridgeToolbar: true)
    }

    func showOnboarding(accessibilityOnly: Bool = false) {
        let view = OnboardingView(accessibilityOnly: accessibilityOnly, finish: { [weak self] in self?.close("onboarding") })
            .environmentObject(AppState.shared)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        Self.makeChromeless(window, hideButtons: false)
        present(id: "onboarding", window: window, view: view, title: "Welcome to Kaiku", recreate: true)
    }

    /// The live transcript in a panel that stays above other windows, on every space, and
    /// never takes the focus from the call. Its frame is remembered.
    func showLiveTranscript() {
        let id = "live"
        if let existing = windows[id] {
            existing.orderFrontRegardless()
            return
        }
        let hosting = NSHostingController(rootView: LiveWindowView(live: AppState.shared.live))
        hosting.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: LiveWindowView.size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.title = "Live Transcript"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier(id)
        panel.minSize = LiveWindowView.minSize
        panel.setContentSize(LiveWindowView.size)
        let autosave = "kaiku.live"
        if !panel.setFrameUsingName(autosave), let screen = NSScreen.main?.visibleFrame {
            // First time: the top right corner, clear of the menu bar popover's usual place.
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - 24))
        }
        panel.setFrameAutosaveName(autosave)
        windows[id] = panel
        panel.orderFrontRegardless()
    }

    /// Transparent title bar, content up to the top edge.
    static func makeChromeless(_ window: NSWindow, hideButtons: Bool) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        if hideButtons {
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(b)?.isHidden = true
            }
        }
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    private func present<V: View>(id: String, window: NSWindow, view: V, title: String,
                                  recreate: Bool, bridgeToolbar: Bool = false, size: NSSize? = nil) {
        if let existing = windows[id], !recreate {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        windows[id]?.close()
        let hosting = NSHostingController(rootView: view)
        if bridgeToolbar { hosting.sceneBridgingOptions = [.toolbars, .title] }
        window.contentViewController = hosting
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        if let size { window.setContentSize(size) }
        window.center()
        windows[id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        if windows[id] === window { windows[id] = nil }
    }
}

/// Panel that can become key so its text field takes input immediately.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
