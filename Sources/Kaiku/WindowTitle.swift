import AppKit
import ApplicationServices

/// Reads the title of an app's front window through Accessibility. nil without the
/// permission or when the app has no titled window.
@MainActor
enum WindowTitle {
    /// - Parameters:
    ///   - pid: the process using the mic, often a helper without windows.
    ///   - bundleID: that process's bundle id.
    ///   - bundlePrefixes: bundle id prefixes of the app it belongs to.
    static func front(pid: pid_t, bundleID: String, bundlePrefixes: [String]) -> String? {
        guard AXIsProcessTrusted(), let app = owningApp(pid: pid, bundleID: bundleID, bundlePrefixes: bundlePrefixes) else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &window) == .success,
                  let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { continue }
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
               let text = title as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return nil
    }

    /// The regular app a mic-using process belongs to: the process itself when it has
    /// windows, else the running app whose bundle id prefixes the helper's (e.g.
    /// com.google.Chrome for com.google.Chrome.helper), else any app of the family.
    private static func owningApp(pid: pid_t, bundleID: String, bundlePrefixes: [String]) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
        let family = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
            return bundlePrefixes.contains { id.hasPrefix($0) }
        }
        return family.first { app in app.bundleIdentifier.map { bundleID.hasPrefix($0) } ?? false }
            ?? family.first(where: \.isActive) ?? family.first
    }
}
