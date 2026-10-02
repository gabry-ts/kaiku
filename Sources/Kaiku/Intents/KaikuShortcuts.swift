import AppIntents

/// The phrases Siri and Spotlight offer without any setup in Shortcuts.
struct KaikuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record a call with \(.applicationName)",
                "\(.applicationName) start recording",
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "\(.applicationName) stop recording",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: TogglePauseIntent(),
            phrases: [
                "Pause recording in \(.applicationName)",
                "Resume recording in \(.applicationName)",
            ],
            shortTitle: "Pause or Resume",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: AddBookmarkIntent(),
            phrases: [
                "Add a bookmark in \(.applicationName)",
                "Bookmark this moment in \(.applicationName)",
            ],
            shortTitle: "Add Bookmark",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: ToggleMicrophonesIntent(),
            phrases: [
                "Mute my microphones in \(.applicationName)",
                "Unmute my microphones in \(.applicationName)",
            ],
            shortTitle: "Mute or Unmute",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: LastCallIntent(),
            phrases: [
                "Get my last call from \(.applicationName)",
                "What was my last call in \(.applicationName)",
            ],
            shortTitle: "Last Call",
            systemImageName: "phone.arrow.down.left"
        )
        AppShortcut(
            intent: FindCallsIntent(),
            phrases: [
                "Find calls in \(.applicationName)",
                "Search my calls in \(.applicationName)",
            ],
            shortTitle: "Find Calls",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: GetTranscriptIntent(),
            phrases: [
                "Get the last transcript from \(.applicationName)",
                "Show my last transcript in \(.applicationName)",
            ],
            shortTitle: "Get Transcript",
            systemImageName: "text.alignleft"
        )
        AppShortcut(
            intent: GetSummaryIntent(),
            phrases: [
                "Get the last summary from \(.applicationName)",
                "Summarize my last call with \(.applicationName)",
            ],
            shortTitle: "Get Summary",
            systemImageName: "doc.text"
        )
        AppShortcut(
            intent: GenerateSummaryIntent(),
            phrases: [
                "Write a summary of my last call in \(.applicationName)",
            ],
            shortTitle: "Generate Summary",
            systemImageName: "sparkles"
        )
    }
}
