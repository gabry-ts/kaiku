import SwiftUI

@main
struct KaikuApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Color("AccentColor"))
                .transaction { $0.animation = nil }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Record", systemImage: "mic.fill") { Text("Record") }
            Tab("Library", systemImage: "books.vertical") { Text("Library") }
            Tab("Settings", systemImage: "gearshape") { Text("Settings") }
        }
    }
}
