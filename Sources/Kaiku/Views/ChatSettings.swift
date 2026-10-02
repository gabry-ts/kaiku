import AppKit
import KaikuCore
import PartitiUI
import SwiftUI

/// Settings > Chat: who answers questions about calls in the library.
struct ChatSettings: View {
    @AppStorage(Keys.summaryProvider) private var summaryProvider = SummaryProviderKind.openAI.rawValue
    @AppStorage(Keys.chatProvider) private var chatProvider = ""
    @State private var model = ""
    @StateObject private var access = ProviderAccess()

    private var kind: SummaryProviderKind {
        SummaryProviderKind(rawValue: chatProvider) ?? SummaryProviderKind(rawValue: summaryProvider) ?? .openAI
    }

    private var footer: String {
        "Chats stay on this Mac, in Chats in your recordings folder. Each question sends the calls in the chat to the provider chosen here, with your own key or command-line tool, and nothing else leaves your Mac. "
            + (kind.cli == nil
                ? "\(kind.displayName) gets the transcripts in the message, as many of the most recent ones as fit."
                : "\(kind.displayName) gets the paths of the transcripts and summaries and reads them itself, without changing them.")
    }

    var body: some View {
        KaikuPane(pane: .chat, subtitle: "Ask questions about one or more calls from the library.") {
            SettingsGroup(Text("Provider"), footer: Text(footer)) {
                SettingsRow("Provider") {
                    Picker("Provider", selection: Binding(get: { kind.rawValue }, set: { chatProvider = $0 })) {
                        ForEach(SummaryProviderKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ModelField(kind: kind, text: $model,
                           subtitle: kind.cli == nil ? "Answers appear as they are written." : "Reads the calls first, so the answer takes a little longer.")
                ProviderAccessRows(access: access, modelMissing: kind.requiresModel && model.isEmpty)
            }
            SettingsGroup("Saved Chats", footer: "Delete a chat from its list in the library, or remove its file here.") {
                SettingsRow(Text("Saved in"), subtitle: Text(AppSettings.baseFolderDisplayPath + "/Chats")) {
                    Button("Show in Finder", action: showFolder)
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: summaryProvider) { _, _ in load() }
        .onChange(of: chatProvider) { _, _ in load() }
        .onChange(of: model) { _, v in
            AppSettings.defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: Keys.chatModel(kind))
        }
    }

    private func load() {
        model = AppSettings.chatModel(for: kind)
        access.load(kind)
    }

    private func showFolder() {
        let folder = AppSettings.chatsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
