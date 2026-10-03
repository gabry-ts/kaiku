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

    /// The open window with this id, if any.
    func window(_ id: String) -> NSWindow? { windows[id] }

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
        // Stays where it opened: not draggable, and moved back if a window manager moves it.
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        titleAnchor = NSPoint(x: panel.frame.midX, y: panel.frame.maxY)
    }

    /// Top center of the title prompt when it opened; it grows downwards from there.
    private var titleAnchor: NSPoint?

    /// Opens the main window on Settings, on `pane` (the last one shown when nil), scrolled to
    /// the row `anchor`. An open window switches to it.
    func showSettings(_ pane: SettingsPane? = nil, anchor: String? = nil) {
        AppNavigation.shared.open(pane, anchor: anchor)
        AppNavigation.shared.showingSettings = true
        showMain()
    }

    /// Opens the main window on the calls.
    func showLibrary() {
        AppNavigation.shared.closeSettings()
        showMain()
    }

    /// The main window, Kaiku: the calls, the chat and Settings in one resizable window.
    private func showMain() {
        let view = LibraryView().environmentObject(AppState.shared).defaultAppStorage(AppSettings.defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("kaiku.library")
        present(id: Self.mainID, window: window, view: view, title: "Kaiku", recreate: false, bridgeToolbar: true)
    }

    /// Id of the main window.
    static let mainID = "main"

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
        let hosting = NSHostingController(rootView: LiveWindowView(live: AppState.shared.live).withoutAnimations())
        hosting.sizingOptions = []
        let panel = Self.makeLivePanel()
        panel.contentViewController = hosting
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

    /// The floating panel of the live transcript, without content: a clear title bar over
    /// a full-size content view, so the view's material and header run under the close button.
    static func makeLivePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: LiveWindowView.size),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Live Transcript"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
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
        let hosting = NSHostingController(rootView: view.withoutAnimations())
        if bridgeToolbar { hosting.sceneBridgingOptions = [.toolbars, .title] }
        window.contentViewController = hosting
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        if let size { window.setContentSize(size) }
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        windows[id] = window
        updateDockPresence()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.identifier?.rawValue == "title" else { return }
        recenter(window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.identifier?.rawValue == "title" else { return }
        recenter(window)
    }

    /// Puts the title prompt back where it opened.
    private func recenter(_ window: NSWindow) {
        guard let anchor = titleAnchor else { return }
        let origin = NSPoint(x: (anchor.x - window.frame.width / 2).rounded(),
                             y: (anchor.y - window.frame.height).rounded())
        if abs(window.frame.origin.x - origin.x) > 1 || abs(window.frame.origin.y - origin.y) > 1 {
            window.setFrameOrigin(origin)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        if windows[id] === window { windows[id] = nil }
        updateDockPresence()
    }

    /// The window that puts Kaiku in the Dock and the app switcher while open, so it is easy to find again.
    private static let dockWindows: Set<String> = [mainID]

    /// A Dock icon while the main window is open (when enabled), else menu bar only.
    func updateDockPresence() {
        let show = AppSettings.showInDock && windows.keys.contains { Self.dockWindows.contains($0) }
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}

/// Panel that can become key so its text field takes input immediately.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension View {
    /// Kaiku shows every change at once: no springs, fades or animated resizes, including
    /// the ones built into PartitiUI controls.
    func withoutAnimations() -> some View {
        transaction { t in
            t.animation = nil
            t.disablesAnimations = true
        }
    }
}
