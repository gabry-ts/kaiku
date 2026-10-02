import KaikuCore
import PartitiUI
import SwiftUI

/// The tasks taken from a call, with checkboxes and a menu to send the checked ones.
struct ActionItemsSection: View {
    @EnvironmentObject var state: AppState
    let folder: RecordingFolder

    @State private var items: [ActionItem] = []
    @State private var checked: Set<String> = []
    /// Items already offered, so a reload does not check again what the user unchecked.
    @State private var seen: Set<String> = []
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Action Items").font(.headline)
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Menu {
                    ForEach(ActionDestination.allCases, id: \.self) { destination in
                        Button(destination.displayName) { send(to: destination) }
                            .disabled(pending(for: destination).isEmpty)
                    }
                } label: {
                    Label("Send to…", systemImage: "paperplane")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(sending || checked.isEmpty)
            }
            ForEach(items) { item in
                row(item)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(PUI.Space.l).puiSurface(radius: PUI.Radius.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.disabled)
        .onAppear(perform: reload)
        .onChange(of: state.libraryVersion) { _, _ in reload() }
    }

    private func row(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: Binding(get: { checked.contains(item.id) }, set: { on in
                if on { checked.insert(item.id) } else { checked.remove(item.id) }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.text)
                    if let detail = detail(item) {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            ForEach(item.sentTo, id: \.self) { destination in
                Label(destination.displayName, systemImage: "checkmark")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .help("Sent to \(destination.displayName)")
            }
        }
    }

    private func detail(_ item: ActionItem) -> String? {
        let parts = [item.owner, item.due.map { "Due \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Checked items not yet sent to the destination.
    private func pending(for destination: ActionDestination) -> [ActionItem] {
        items.filter { checked.contains($0.id) && !$0.sentTo.contains(destination) }
    }

    private func reload() {
        items = folder.loadActionItems()
        let ids = Set(items.map(\.id))
        checked.formIntersection(ids)
        // Items that are yours start checked, unless they were sent already.
        for item in items where !seen.contains(item.id) {
            if ActionItems.isOwnedByUser(item.owner, meLabel: AppSettings.meLabel), item.sentTo.isEmpty { checked.insert(item.id) }
        }
        seen.formUnion(ids)
    }

    private func send(to destination: ActionDestination) {
        let toSend = pending(for: destination)
        guard !toSend.isEmpty else { return }
        sending = true
        error = nil
        Task {
            do { try await ActionItemSender.send(toSend, to: destination, folder: folder) }
            catch { self.error = error.localizedDescription }
            reload()
            sending = false
        }
    }
}
