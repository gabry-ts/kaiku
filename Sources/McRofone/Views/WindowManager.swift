import AppKit
import McRofoneCore
import SwiftUI

/// Opens AppKit windows hosting SwiftUI views. A menubar-only app has to
/// activate itself explicitly, otherwise windows open behind other apps.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var windows: [String: NSWindow] = [:]

    func showTitlePrompt(title: String, event: CalendarEventInfo?) {
        let view = TitlePromptView(onDone: { [weak self] in self?.close("title") }, initialTitle: title, event: event)
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
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        present(id: "settings", window: window, view: view, title: "Settings", recreate: false, bridgeToolbar: true)
    }

    func showLibrary() {
        let view = LibraryView().environmentObject(AppState.shared).defaultAppStorage(AppSettings.defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("mcrofone.library")
        present(id: "library", window: window, view: view, title: "Recordings", recreate: false, bridgeToolbar: true)
    }

    func showOnboarding() {
        let view = OnboardingView(finish: { [weak self] in self?.close("onboarding") })
            .environmentObject(AppState.shared)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        Self.makeChromeless(window, hideButtons: false)
        present(id: "onboarding", window: window, view: view, title: "Welcome to mc.Rofone", recreate: true)
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
                                  recreate: Bool, bridgeToolbar: Bool = false) {
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
