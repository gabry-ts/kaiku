import AppIntents

/// Phrases for Siri and the Shortcuts app; they also make the actions pickable for the Action Button.
struct KaikuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording in \(.applicationName)", "Record a meeting with \(.applicationName)"],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill")
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording in \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.fill")
    }
}
