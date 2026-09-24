import SwiftUI
import KaikuCore

/// First-run guide: what it does, permissions, provider, done.
struct OnboardingView: View {
    @State var step = 0
    var finish: () -> Void = {}
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: PermissionsStep()
                case 2: ProviderStep()
                default: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Brand.accent : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(step + 1) of \(steps)")
                Spacer()
                if step > 0 && step < steps - 1 {
                    Button("Back") { withAnimation(.snappy) { step -= 1 } }
                }
                Button(step == steps - 1 ? "Start Using Kaiku" : "Continue") {
                    if step == steps - 1 {
                        AppSettings.defaults.set(true, forKey: Keys.onboardingDone)
                        finish()
                    } else {
                        withAnimation(.snappy) { step += 1 }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primary)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 600, height: 540)
        .defaultAppStorage(AppSettings.defaults)
    }
}

private struct StepHeader: View {
    let symbol: String?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Brand.accent.gradient)
                    .padding(.bottom, 2)
            }
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 22) {
            AppIconView().frame(width: 104, height: 104)
            StepHeader(symbol: nil, title: "Welcome to Kaiku",
                       subtitle: "Your calls, recorded and transcribed. No meeting bot, no subscription.")
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "person.crop.circle.badge.xmark", title: "No bot in the call",
                        text: "Records your microphone and what your Mac plays, from any app.")
                Feature(symbol: "text.bubble", title: "Transcripts you control",
                        text: "Transcribe on this Mac with whisper.cpp, or with your own API key.")
                Feature(symbol: "folder", title: "Always in the same place",
                        text: "Every call gets a folder with the audio and a Markdown transcript.")
            }
            .frame(maxWidth: 420)
        }
        .padding(28)
    }

    private struct Feature: View {
        let symbol: String
        let title: String
        let text: String
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Brand.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(text).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "lock.shield", title: "A few permissions",
                       subtitle: "Kaiku only listens while you're recording.")
            VStack(spacing: 12) {
                PermissionRow(symbol: "mic.fill", tint: Brand.accent, title: "Microphone",
                              detail: "To record your side of the call.", state: permissions.microphone,
                              action: permissions.microphone == .notAsked ? "Allow" : "Open Settings…",
                              perform: { permissions.requestMicrophone() })
                Divider()
                PermissionRow(symbol: "speaker.wave.2.fill", tint: .blue, title: "System Audio Recording",
                              detail: "To hear the other people. macOS asks on your first recording.",
                              state: .unknown, action: "Open Settings…",
                              perform: { Permissions.open(.systemAudio) })
                Divider()
                PermissionRow(symbol: "bell.badge.fill", tint: .orange, title: "Notifications",
                              detail: "To tell you when a transcript is ready.", state: permissions.notifications,
                              action: permissions.notifications == .notAsked ? "Allow" : "Open Settings…",
                              perform: { permissions.requestNotifications() })
                Divider()
                PermissionRow(symbol: "calendar", tint: .red, title: "Calendar (optional)",
                              detail: "To name recordings after the meeting you're in.", state: permissions.calendar,
                              action: permissions.calendar == .notAsked ? "Allow" : "Open Settings…",
                              perform: { permissions.requestCalendar() })
            }
            .card()
            .frame(maxWidth: 480)
        }
        .padding(28)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}

private struct ProviderStep: View {
    @AppStorage(Keys.provider) private var provider = ProviderKind.whisperCpp.rawValue
    @ObservedObject private var models = WhisperModels.shared
    @State private var apiKey = ""

    private var kind: ProviderKind { ProviderKind(rawValue: provider) ?? .whisperCpp }

    var body: some View {
        VStack(spacing: 20) {
            StepHeader(symbol: "text.quote", title: "How should calls be transcribed?",
                       subtitle: "You can switch any time in Settings.")
            Picker("Provider", selection: $provider) {
                Text("On this Mac").tag(ProviderKind.whisperCpp.rawValue)
                Text("ElevenLabs").tag(ProviderKind.elevenLabs.rawValue)
                Text("OpenAI").tag(ProviderKind.openAI.rawValue)
                Text("Groq").tag(ProviderKind.groq.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)

            VStack(alignment: .leading, spacing: 10) {
                if kind == .whisperCpp {
                    let model = WhisperModel.recommended
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(Brand.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Private and free").font(.body.weight(.semibold))
                            Text("Uses whisper.cpp with the \(model.name) model (\(model.size)).")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let p = models.progress[model.file] {
                            ProgressView(value: p).frame(width: 90)
                        } else if FileManager.default.fileExists(atPath: AppSettings.whisperModel) {
                            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if model.isInstalled {
                            Button("Use") { models.use(model) }
                        } else {
                            Button("Download") { models.download(model) }
                        }
                    }
                    if !FileManager.default.isExecutableFile(atPath: AppSettings.whisperPath) {
                        StatusDot(kind: .warning, text: "whisper-cli not found. Set its path in Settings.")
                    }
                } else {
                    Text("Paste your \(kind.displayName) API key").font(.body.weight(.semibold))
                    SecureField("API key", text: $apiKey, prompt: Text("API key"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { _, v in Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: kind.rawValue) }
                    HStack {
                        Label("Saved in your Keychain", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let url = kind.keyURL { Link("Get a key", destination: url).font(.caption) }
                    }
                }
            }
            .card()
            .frame(maxWidth: 480)
            .onChange(of: provider) { _, _ in apiKey = Keychain.get(kind.rawValue) ?? "" }
            .onAppear { apiKey = Keychain.get(kind.rawValue) ?? "" }
        }
        .padding(28)
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "checkmark.circle", title: "You're all set",
                       subtitle: "Start a recording from the menu bar icon, or with the keyboard shortcut.")
            if let combo = Shortcuts.combo(for: .record) {
                HStack(spacing: 6) {
                    ForEach(Array(combo.displayParts.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .padding(.horizontal, key.count > 1 ? 10 : 0)
                            .frame(minWidth: 40, minHeight: 40)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
                    }
                }
                .accessibilityLabel("Shortcut \(combo.display)")
            }
            Label("Transcripts are saved in \((AppSettings.baseFolder.path as NSString).abbreviatingWithTildeInPath)",
                  systemImage: "folder")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
    }
}
