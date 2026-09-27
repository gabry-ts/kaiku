import AppKit

/// Opens the "Buy Me a Coffee" page, from the menu bar and Settings > About.
enum BuyMeACoffee {
    static func open() {
        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/gabrielepartiti")!)
    }
}
