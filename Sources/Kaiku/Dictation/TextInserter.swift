import AppKit
import Carbon.HIToolbox

/// Puts dictated text where the cursor is in the app in front: through the clipboard and a
/// synthesized ⌘V, then the clipboard gets its previous contents back. Synthesizing keys
/// needs Accessibility; without it the text is only copied.
@MainActor
enum TextInserter {
    enum Outcome { case pasted, copied }

    /// How long the target app gets to read the clipboard before it is restored.
    private static let restoreDelay: TimeInterval = 0.8

    static var canPaste: Bool { AXIsProcessTrusted() }

    static func insert(_ text: String) -> Outcome {
        let pasteboard = NSPasteboard.general
        guard canPaste else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copied
        }
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard managers skip items marked as transient.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = pasteboard.changeCount
        pressCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // Something else copied in the meantime: leave it.
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return .pasted
    }

    /// Copies of every item on the clipboard, with all their types.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        // Only ⌘, even if a modifier of the dictation shortcut is still held.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
