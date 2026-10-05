import SwiftUI

@main
struct KaikuApp: App {
    @State private var recorder = MeetingRecorder()
    @State private var store = LibraryStore()
    private let launch = Date()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(recorder)
                .environment(store)
                .tint(Color("AccentColor"))
                .transaction { $0.animation = nil }
                .task {
                    recorder.onFinished = { _ in store.reload() }
                    // Saves the audio of a recording the app left open when it quit.
                    let launch = launch
                    await Task.detached { MeetingRecorder.recoverInterrupted(base: PhoneSettings.baseFolder, launch: launch) }.value
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Record", systemImage: "mic.fill") { RecordView() }
            Tab("Library", systemImage: "books.vertical") { LibraryView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
    }
}
