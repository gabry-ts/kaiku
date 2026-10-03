import EventKit
import KaikuCore
import PartitiUI
import SwiftUI

/// Settings > Transcription > Action Items: where the tasks of a call can be sent from the library.
struct ActionItemsSettings: View {
    @AppStorage(Keys.remindersListID) private var remindersList = ""
    @AppStorage(Keys.linearTeamID) private var teamID = ""
    @AppStorage(Keys.linearProjectID) private var projectID = ""
    @State private var lists: [EKCalendar] = []
    @State private var remindersState = RemindersService.shared.state
    @State private var linearKey = ""
    @State private var teams: [ActionItems.LinearChoice] = []
    @State private var projects: [ActionItems.LinearChoice] = []
    @State private var linearError: String?

    var body: some View {
        SettingsGroup("Action Items", footer: "Every summary also lists the tasks of the call. Send them from the call in the library: nothing leaves your Mac until you do. Things needs no setup.") {
            remindersRows
            if linearKey.isEmpty {
                SettingsRow(Text("Linear"), subtitle: Text("Connect Linear to send tasks to a team.")) {
                    SetUpButton(service: .linear)
                }
            } else {
                SettingsRow("Linear team") {
                    Picker("Linear team", selection: $teamID) {
                        Text("None").tag("")
                        ForEach(teams) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("Linear project") {
                    Picker("Linear project", selection: $projectID) {
                        Text("None").tag("")
                        ForEach(projects) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(teamID.isEmpty)
                }
                if let linearError {
                    GroupRow { StatusDot(kind: .error, text: linearError) }
                }
            }
        }
        .onAppear {
            linearKey = LinearAPI.key ?? ""
            loadLists()
        }
        .task(id: linearKey) { await loadTeams() }
        .onChange(of: teamID) { _, _ in projectID = "" }
        .task(id: teamID) { await loadProjects() }
    }

    @ViewBuilder private var remindersRows: some View {
        switch remindersState {
        case .granted:
            SettingsRow("Reminders list") {
                Picker("Reminders list", selection: $remindersList) {
                    Text("None").tag("")
                    ForEach(lists, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                }
                .labelsHidden()
                .fixedSize()
            }
        case .notAsked:
            SettingsRow(Text("Reminders list"), subtitle: Text("Kaiku needs access to your reminders.")) {
                Button("Allow…") {
                    Task {
                        _ = await RemindersService.shared.requestAccess()
                        loadLists()
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            }
        default:
            SettingsRow(Text("Reminders list"), subtitle: Text("Access to Reminders is off for Kaiku.")) {
                Button("Open Settings…") { RemindersService.openPrivacySettings() }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            }
        }
    }

    private func loadLists() {
        remindersState = RemindersService.shared.state
        lists = RemindersService.shared.lists()
    }

    private func loadTeams() async {
        teams = []
        linearError = nil
        let key = linearKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // Let typing finish before asking Linear.
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return }
        do { teams = try await LinearAPI.teams() } catch { linearError = error.localizedDescription }
    }

    private func loadProjects() async {
        projects = []
        guard !teamID.isEmpty, !linearKey.isEmpty else { return }
        do { projects = try await LinearAPI.projects(teamID: teamID) } catch { linearError = error.localizedDescription }
    }
}
