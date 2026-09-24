import SwiftUI
import KaikuCore

/// Shown when recording starts: call title (prefilled), per-call language, mic in use.
struct TitlePromptView: View {
    @EnvironmentObject var state: AppState
    let onDone: () -> Void
    var event: CalendarEventInfo?

    @State private var title: String
    @State private var language = AppSettings.language
    @State private var useEvent = true
    @State private var tags: [String] = []
    @State private var knownTags: [String] = []

    init(onDone: @escaping () -> Void, initialTitle: String? = nil, event: CalendarEventInfo? = nil) {
        self.onDone = onDone
        self.event = event
        _title = State(initialValue: initialTitle ?? Naming.defaultTitle(date: Date()))
    }
    @FocusState private var focused: Bool

    private var micName: String? {
        AudioDevices.resolveMicrophone(setting: AppSettings.microphone)?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Brand.accent)
                    .symbolEffect(.pulse, options: .repeating)
                VStack(alignment: .leading, spacing: 0) {
                    Text("New Recording").font(.headline)
                    Text("Name the call so you can find it later.").font(.callout).foregroundStyle(.secondary)
                }
            }

            TextField("Title", text: $title, prompt: Text("What's this call about?"))
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Brand.accent.opacity(0.7) : Color.secondary.opacity(0.25), lineWidth: focused ? 2 : 1))
                .focused($focused)
                .onSubmit(start)
                .accessibilityLabel("Call title")

            TagField(tags: $tags, known: knownTags, lastUsed: state.lastTags, placeholder: "Add a tag, e.g. a project",
                     onSubmitEmpty: start)
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))

            HStack(spacing: 8) {
                Menu {
                    Picker("Language", selection: $language) {
                        Text("Auto-detect").tag("auto")
                        Text("Italian").tag("it")
                        Text("English").tag("en")
                        if !["auto", "it", "en"].contains(language) {
                            Text(LanguagePicker.displayName(language)).tag(language)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(LanguagePicker.displayName(language), systemImage: "globe")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
                .help("Language for this call")

                Label(micName ?? "Call audio only", systemImage: micName == nil ? "mic.slash" : "mic")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Change the microphone in Settings > Recording")
                Spacer()
            }

            if let event {
                Toggle(isOn: $useEvent) {
                    Label {
                        Text(eventSummary(event)).lineLimit(1)
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Save the event and its attendees with this call")
            }

            Label(AppSettings.baseFolderDisplayPath, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button(action: start) {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primary)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            knownTags = state.knownTags()
            DispatchQueue.main.async { focused = true }
        }
    }

    private func start() {
        let t = title
        let l = language
        let e = useEvent ? event : nil
        let tg = tags
        onDone()
        Task { await state.startRecording(title: t, language: l, event: e, tags: tg) }
    }

    private func eventSummary(_ e: CalendarEventInfo) -> String {
        var parts = ["From \(e.calendar ?? "your calendar")"]
        let n = e.attendeeNames.count
        if n > 0 { parts.append("\(n) attendee\(n == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
