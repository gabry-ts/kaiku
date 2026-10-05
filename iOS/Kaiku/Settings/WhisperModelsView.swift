import SwiftUI
import KaikuCore

/// Whisper models on this iPhone: download, choose and delete.
struct WhisperModelsView: View {
    @State private var downloader = WhisperDownloader.shared

    var body: some View {
        List {
            Section {
                ForEach(WhisperModel.phoneCatalog) { model in
                    ModelRow(model: model, downloader: downloader)
                }
            } footer: {
                Text("Models run on this iPhone. Larger models are more accurate but slower and use more battery.")
            }
        }
        .navigationTitle("Whisper models")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    let downloader: WhisperDownloader

    var body: some View {
        let _ = downloader.version
        let installed = model.isInstalled
        let active = installed && WhisperDownloader.activeModel?.file == model.file
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.name).font(.headline)
                    Text("\(model.size) · \(model.note)").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if let value = downloader.progress[model.file] {
                    Button("Cancel") { downloader.cancel(model) }.buttonStyle(.borderless)
                    ProgressView(value: value).frame(width: 60)
                } else if active {
                    Label("In use", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(Color.accentColor)
                } else if installed {
                    Button("Use") { downloader.use(model) }.buttonStyle(.borderless)
                } else {
                    Button("Download") { downloader.download(model) }.buttonStyle(.borderless)
                }
            }
            if let error = downloader.errors[model.file] {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .swipeActions {
            if installed { Button("Delete", role: .destructive) { downloader.delete(model) } }
        }
    }
}
