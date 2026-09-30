import PartitiUI
import SwiftUI

/// Whether a speech model is ready and its download, for a settings section.
@MainActor
final class SpeechModelStatus: ObservableObject {
    /// Nil until the first check comes back.
    @Published private(set) var readiness: LiveReadiness?
    @Published private(set) var downloadError: String?
    /// True while this object's own download runs, so a status check doesn't replace its progress.
    private var downloading = false

    /// Snapshot rendering only: shown instead of asking the system.
    func show(_ readiness: LiveReadiness) {
        self.readiness = readiness
    }

    func refresh(_ check: () async -> LiveReadiness) async {
        guard !downloading else { return }
        let state = await check()
        guard !downloading else { return }
        readiness = state
    }

    /// Runs `download`, showing its progress, then checks again.
    func download(_ download: (@escaping @Sendable (Double) -> Void) async throws -> Void,
                  check: () async -> LiveReadiness) async {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        downloadError = nil
        readiness = .downloading(0)
        do {
            try await download { fraction in
                Task { @MainActor in
                    if self.downloading { self.readiness = .downloading(fraction) }
                }
            }
        } catch {
            downloadError = "Couldn't download the speech model: \(error.localizedDescription)"
        }
        readiness = await check()
    }
}

/// The status row of a speech model: checking, ready, to download, downloading or unusable.
struct SpeechModelStatusRow: View {
    let readiness: LiveReadiness?
    /// The line shown when the model is ready.
    let readyText: String
    /// What waits for the download, added to the reason it is needed.
    let downloadNote: String
    let download: () -> Void

    var body: some View {
        switch readiness {
        case nil:
            GroupRow {
                HStack(spacing: PUI.Space.m) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(PUI.Font.callout).foregroundStyle(.secondary)
                }
            }
        case .ready:
            GroupRow { StatusDot(kind: .ok, text: readyText) }
        case .needsDownload(let what):
            GroupRow {
                HStack(spacing: PUI.Space.l) {
                    StatusDot(kind: .warning, text: "\(what) \(downloadNote)")
                    Spacer(minLength: 0)
                    Button("Download", action: download)
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
            }
        case .downloading(let progress):
            GroupRow {
                HStack(spacing: PUI.Space.l) {
                    Text("Downloading the speech model… \(Int(progress * 100))%")
                        .font(PUI.Font.callout).monospacedDigit().foregroundStyle(.secondary)
                    ProgressView(value: min(max(progress, 0), 1)).controlSize(.small)
                }
            }
        case .unavailable(let why):
            GroupRow { StatusDot(kind: .error, text: why) }
        }
    }
}
