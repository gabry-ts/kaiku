import SwiftUI

@main
struct KaikuApp: App {
    @State private var recorder = MeetingRecorder()
    @State private var store = LibraryStore()
    @State private var jobs = PhoneJobs.shared
    private let launch = Date()

    init() {
        PhoneJobs.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(recorder)
                .environment(store)
                .environment(jobs)
                .tint(Color("AccentColor"))
                .transaction { $0.animation = nil }
                .task {
                    recorder.onFinished = { folder in jobs.enqueue(folder) }
                    jobs.onChange = { store.reload() }
                    // Saves the audio of a recording the app left open when it quit.
                    let launch = launch
                    await Task.detached {
                        MeetingRecorder.recoverInterrupted(base: PhoneSettings.baseFolder, launch: launch)
                        PhoneJobs.markInterrupted(base: PhoneSettings.baseFolder)
                    }.value
                    store.reload()
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
