import KaikuCore

/// Every setting search can find, next to the anchors the panes mark. Rows that change with
/// the data (single sources, whisper models, calendars) aren't listed: their group is, with
/// the words people use for them.
enum SettingsIndex {
    static let all: [SettingsSearchEntry] = general + menuBar + recording + callDetection + transcription
        + ai + accounts + integrations + notifications + permissions + about

    /// The pane and row an entry leads to.
    static func target(of entry: SettingsSearchEntry) -> SettingsTarget? {
        let parts = entry.target.split(separator: "#", maxSplits: 1).map(String.init)
        guard let pane = parts.first.flatMap(SettingsPane.init(rawValue:)) else { return nil }
        return SettingsTarget(pane, parts.count > 1 ? parts[1] : nil)
    }

    private static func e(_ pane: SettingsPane, _ anchor: String, _ group: String, _ title: String,
                          _ keywords: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(target: "\(pane.rawValue)#\(anchor)", pane: pane.title, group: group, title: title, keywords: keywords)
    }

    private static let keyWords = ["key", "api", "token", "password", "credential", "secret", "account"]
    private static let folderWords = ["folder", "location", "path", "save", "disk", "space"]
    private static let cleanupWords = ["delete", "trash", "cleanup", "disk", "space", "storage"]

    private static let general = [
        e(.general, "startup", "Startup", "Open at login", ["dock", "login", "startup", "launch", "boot"]),
        e(.general, "callsFolder", "Calls Folder", "Save calls in", folderWords + ["recordings", "finder"]),
        e(.general, "smartSearch", "Library", "Smart search", ["semantic", "meaning", "smart", "index", "search"]),
        e(.general, "readingWidth", "Library", "Calls and chat width", ["full width", "centered", "column", "layout", "wide", "margins"]),
        e(.general, "storage", "Storage", "Space used", ["disk", "space", "size", "storage"]),
        e(.general, "storage", "Storage", "Delete old audio automatically", cleanupWords + ["audio"]),
        e(.general, "storage", "Storage", "Audio older than", cleanupWords + ["days", "keep"]),
        e(.general, "storage", "Storage", "Clean Up Now", cleanupWords),
    ]

    private static let menuBar = [
        e(.menuBar, "panel", "Panel", "Panel sections", ["popover", "menu", "panel", "menubar", "order", "reorder"]),
        e(.menuBar, "panel", "Panel", "Recent calls to show", ["popover", "recent", "count"]),
        e(.menuBar, "panel", "Panel", "Live transcript in the panel", ["popover", "live"]),
        e(.menuBar, "shortcuts", "Global Shortcuts", "Start or stop recording", ["hotkey", "keyboard", "shortcut", "keys"]),
        e(.menuBar, "shortcuts", "Global Shortcuts", "Pause or resume", ["hotkey", "keyboard", "shortcut", "keys"]),
        e(.menuBar, "shortcuts", "Global Shortcuts", "Add bookmark", ["hotkey", "keyboard", "shortcut", "marker"]),
        e(.menuBar, "shortcuts", "Global Shortcuts", "Mute or unmute all microphones", ["hotkey", "keyboard", "shortcut"]),
        e(.menuBar, "shortcuts", "Global Shortcuts", "Open Kaiku", ["hotkey", "keyboard", "shortcut", "window", "library"]),
        e(.menuBar, "shortcuts", "Global Shortcuts", "Show panel", ["hotkey", "keyboard", "shortcut", "popover"]),
        e(.menuBar, "panelKeys", "Keys in the panel", "Keys in the panel", ["hotkey", "keyboard", "shortcut", "keys"]),
    ]

    private static let recording = [
        e(.recording, "microphone", "Microphone", "Record my microphone", ["mic", "microphone", "input"]),
        e(.recording, "microphone", "Microphone", "Input device", ["mic", "microphone", "input", "bluetooth", "airpods", "headset"]),
        e(.recording, "microphone", "Microphone", "Use the same microphone as the call", ["mic", "follow", "automatic"]),
        e(.recording, "microphone", "Microphone", "Test Microphone", ["mic", "level", "meter"]),
        e(.recording, "callAudio", "Call Audio", "Call audio", ["system audio", "speakers", "other side", "them"]),
        e(.recording, "callAudio", "Call Audio", "Remove echo when using speakers", ["echo", "speakers", "system audio"]),
        e(.recording, "mute", "Mute", "Mute all microphones", ["mute", "silence mic", "teams", "zoom volume"]),
        e(.recording, "mute", "Mute", "Mute by", ["mute", "volume", "switch"]),
        e(.recording, "mute", "Mute", "Volume while muted", ["mute", "teams", "volume"]),
        e(.recording, "forgotten", "Forgotten Recordings", "Stop after a silence of", ["silence", "auto stop", "forgot"]),
        e(.recording, "forgotten", "Forgotten Recordings", "Stop recordings longer than", ["length", "max", "hours", "auto stop"]),
    ]

    private static let callDetection = [
        e(.callDetection, "detection", "Detection", "Notice when a call starts", ["detect", "call", "notice"]),
        e(.callDetection, "detection", "Detection", "Record automatically", ["auto", "automatic", "autostart", "record by itself"]),
        e(.callDetection, "detection", "Detection", "When a call ends", ["end", "stop", "ask"]),
        e(.callDetection, "detection", "Detection", "Stop after", ["delay", "auto stop", "end"]),
        e(.callDetection, "sources", "Sources", "Sources", ["app", "website", "zoom", "teams", "meet", "whatsapp", "facetime", "ignore", "web"]),
        e(.callDetection, "sources", "Sources", "Add an app or website", ["app", "website", "add", "custom"]),
        e(.callDetection, "calendar", "Calendar", "Name calls after calendar events", ["calendar", "event", "meeting name", "attendees", "title"]),
        e(.callDetection, "calendar", "Calendar", "Calendars", ["calendar", "google", "outlook"]),
    ]

    private static let transcription = [
        e(.transcription, "language", "Language", "Default language", ["language", "italian", "english", "auto-detect"]),
        e(.transcription, "provider", "Provider", "whisper.cpp (on this Mac)", ["whisper", "local", "offline", "free"]),
        e(.transcription, "provider", "Provider", "Apple (on this Mac)", ["apple", "speech", "local"]),
        e(.transcription, "provider", "Provider", "ElevenLabs Scribe", ["elevenlabs", "scribe", "diarization"]),
        e(.transcription, "provider", "Provider", "OpenAI", ["gpt-4o", "whisper", "cloud"]),
        e(.transcription, "provider", "Provider", "Groq", ["groq", "whisper", "cloud"]),
        e(.transcription, "provider", "Provider", "Alibaba Cloud", ["alibaba", "qwen", "dashscope"]),
        e(.transcription, "model", "Model", "Transcription model", ["whisper", "model", "download", "large", "turbo"]),
        e(.transcription, "model", "Model", "Test the provider", ["test", "check"]),
        e(.transcription, "speakers", "Speaker Names", "Your microphone name", ["speaker", "names", "me", "diarization"]),
        e(.transcription, "speakers", "Speaker Names", "Call audio name", ["speaker", "names", "others", "them"]),
        e(.transcription, "live", "Live Transcription", "Show the transcript while recording", ["live", "realtime", "captions", "subtitles", "during the call"]),
        e(.transcription, "live", "Live Transcription", "Live engine", ["live", "realtime", "openai realtime", "elevenlabs"]),
        e(.transcription, "live", "Live Transcription", "After the call", ["live", "preview", "transcript"]),
        e(.transcription, "advanced", "Advanced", "whisper-cli", ["whisper", "cli", "path", "binary"]),
        e(.transcription, "advanced", "Advanced", "Skip long silences", ["silence", "trim", "pauses"]),
        e(.transcription, "advanced", "Advanced", "Cost estimate", ["price", "cost", "dollars", "billing"]),
    ]

    private static let ai = [
        e(.ai, "summaries", "Summaries", "Summarize every call after transcription", ["summary", "summarize", "recap", "notes"]),
        e(.ai, "summaryProvider", "Summaries", "Summary provider", ["gpt", "claude", "anthropic", "openrouter", "ollama", "llama", "local llm", "codex", "opencode", "cli"]),
        e(.ai, "summaryPrompt", "Summaries", "Customize Prompt", ["prompt", "summary", "instructions"]),
        e(.ai, "liveAssist", "Live Assist", "Summarize and answer questions during calls", ["assist", "ask", "questions during", "live summary"]),
        e(.ai, "chat", "Chat", "Chat provider", ["chat", "ask calls", "conversation", "gpt", "claude", "ollama"]),
        e(.ai, "savedChats", "Chat", "Saved chats", ["chat", "folder", "history"]),
    ]

    private static let accounts: [SettingsSearchEntry] = AccountService.allCases.map { service in
        let group: String
        switch service.group {
        case .cloud: group = "Cloud Services"
        case .network: group = "On Your Network"
        case .cli: group = "Command-Line Tools"
        case .apps: group = "Apps"
        }
        let title = service.keyAccount != nil && service != .custom ? "\(service.displayName) API key" : service.displayName
        var words = keyWords
        switch service {
        case .ollama: words = ["ollama", "llama", "local llm", "server", "address"]
        case .custom: words += ["lm studio", "local llm", "server", "address"]
        case .claudeCode: words = ["claude", "cli", "anthropic", "path"]
        case .codex, .opencode: words = ["cli", "path"]
        case .openAI: words += ["gpt"]
        case .anthropic: words += ["claude"]
        default: break
        }
        return e(.accounts, service.anchor, group, title, words)
    }

    private static let integrations = [
        e(.integrations, "actionItems", "Action Items", "Reminders list", ["reminders", "tasks", "todo", "action items"]),
        e(.integrations, "actionItems", "Action Items", "Linear team", ["linear", "tasks", "issues", "action items"]),
        e(.integrations, "actionItems", "Action Items", "Things", ["things", "tasks", "todo"]),
        e(.integrations, "webhook", "Webhook", "Send a webhook when a transcript is ready", ["webhook", "zapier", "make", "n8n", "http", "post"]),
        e(.integrations, "webhook", "Webhook", "Headers", ["api key", "token", "authorization", "header"]),
        e(.integrations, "webhook", "Webhook", "Custom Template", ["body", "json", "template"]),
        e(.integrations, "agents", "Agents (MCP)", "Add to Claude Code", ["mcp", "agent", "claude code", "claude desktop", "codex"]),
        e(.integrations, "agentsEdit", "Agents (MCP)", "Allow agents to edit calls", ["mcp", "agent", "edit", "permission"]),
        e(.integrations, "agents", "Agents (MCP)", "Manual Setup", ["mcp", "snippet", "config"]),
        e(.integrations, "raycast", "Raycast", "Install in Raycast", ["raycast", "extension"]),
    ]

    private static let notifications: [SettingsSearchEntry] = [
        e(.notifications, "system", "Notifications", "Notifications from Kaiku", ["sound", "banner", "alert", "notification"]),
    ] + NotificationKind.allCases.map { kind in
        let group: String
        switch kind {
        case .callDetected, .newSource, .recordingStarted, .callEnded, .recordingStopped: group = "calls"
        case .transcriptReady, .recovered, .cleanup: group = "transcripts"
        default: group = "problems"
        }
        return e(.notifications, group, group == "calls" ? "Calls" : group == "transcripts" ? "Calls and Transcripts" : "Problems",
                 kind.title, ["sound", "banner", "alert", "notification"])
    }

    private static let permissions = [
        e(.permissions, "microphone", "Permissions", "Microphone access", ["permission", "privacy", "mic"]),
        e(.permissions, "systemAudio", "Permissions", "System Audio Recording", ["permission", "privacy", "call audio"]),
        e(.permissions, "notifications", "Permissions", "Notifications access", ["permission", "privacy"]),
        e(.permissions, "calendar", "Permissions", "Calendar access", ["permission", "privacy"]),
        e(.permissions, "accessibility", "Permissions", "Accessibility", ["permission", "privacy", "browser", "window title"]),
        e(.permissions, "reminders", "Permissions", "Reminders access", ["permission", "privacy"]),
    ]

    private static let about = [
        e(.about, "updates", "About", "Check for Updates", ["update", "version", "sparkle"]),
        e(.about, "updates", "About", "Buy Me a Coffee", ["coffee", "donate", "support"]),
        e(.about, "help", "Help", "Show Welcome Guide", ["welcome", "onboarding", "help", "guide"]),
    ]
}
