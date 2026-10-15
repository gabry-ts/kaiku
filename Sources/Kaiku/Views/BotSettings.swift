import AppKit
import PartitiUI
import SwiftUI
import UniformTypeIdentifiers
import KaikuCore

/// Settings > Meeting Bot: how the bot shows up in a call and when it leaves.
struct BotSettings: View {
    @AppStorage(Keys.botName) private var name = "Kaiku Notetaker"
    @AppStorage(Keys.botPhotoPath) private var photoPath = ""
    @AppStorage(Keys.botChatMessage) private var message = ""
    @AppStorage(Keys.botLeaveWhenAlone) private var leaveWhenAlone = true
    @AppStorage(Keys.botMaxMinutes) private var maxMinutes = 180
    @AppStorage(Keys.botLobbyMinutes) private var lobbyMinutes = 10
    @AppStorage(Keys.botSummarize) private var summarize = true
    @State private var photoError: String?

    var body: some View {
        KaikuPane(pane: .meetingBot, subtitle: "Joins Google Meet and Microsoft Teams calls for you and records them.") {
            SettingsGroup("Google Chrome", footer: "The bot runs in a hidden Chrome window on this Mac, which must stay awake during the call.") {
                if ChromeLauncher.isInstalled {
                    GroupRow { StatusDot(kind: .ok, text: "Google Chrome is installed") }
                } else {
                    SettingsRow(Text("Google Chrome is not installed")) {
                        Button("Download Chrome…") { NSWorkspace.shared.open(ChromeLauncher.downloadURL) }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
            .settingsAnchor("chrome")

            SettingsGroup("Appearance", footer: "The picture is shown as the bot's camera. Without one the camera stays off.") {
                SettingsRow("Name") {
                    TextField("Name", text: $name, prompt: Text("Kaiku Notetaker"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                SettingsRow(Text("Picture"), subtitle: photoPath.isEmpty ? nil : Text((photoPath as NSString).lastPathComponent)) {
                    HStack(spacing: PUI.Space.s) {
                        if !photoPath.isEmpty, let image = NSImage(contentsOfFile: photoPath) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 22, height: 22).clipShape(Circle())
                        }
                        if !photoPath.isEmpty { Button("Remove") { photoPath = "" } }
                        Button("Choose…", action: choosePhoto)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
                if let photoError {
                    GroupRow { StatusDot(kind: .error, text: photoError) }
                }
                SettingsRow("Message in the chat") {
                    TextField("Message in the chat", text: $message, prompt: Text("None"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
            }
            .settingsAnchor("appearance")

            SettingsGroup("In the Call", footer: "The bot waits in the lobby until someone lets it in.") {
                SwitchRow("Leave when everyone else has left", isOn: $leaveWhenAlone)
                SettingsRow("Give up waiting in the lobby after") {
                    Picker("Give up waiting in the lobby after", selection: $lobbyMinutes) {
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("Leave calls longer than") {
                    Picker("Leave calls longer than", selection: $maxMinutes) {
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                        Text("3 hours").tag(180)
                        Text("4 hours").tag(240)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SwitchRow("Summarize the call afterwards", isOn: $summarize)
            }
            .settingsAnchor("inCall")
        }
    }

    /// Copies the picture into Application Support, so moving the original doesn't lose it.
    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Picture"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kaiku", isDirectory: true)
        let dest = folder.appendingPathComponent("bot-picture." + (url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !photoPath.isEmpty { try? FileManager.default.removeItem(atPath: photoPath) }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            photoPath = dest.path
            photoError = nil
        } catch {
            photoError = "Could not use this picture: \(error.localizedDescription)"
        }
    }
}
