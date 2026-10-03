import PartitiUI
import SwiftUI
import KaikuCore

/// Lets audio and video files be dropped on the call list, adds the Import button,
/// and shows how far the import is.
private struct ImportDropTarget: ViewModifier {
    @ObservedObject private var importer = CallImporter.shared
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                importer.importFiles(urls)
                return !urls.isEmpty
            } isTargeted: { targeted = $0 }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: PUI.Radius.group)
                        .strokeBorder(AppAccent.kaiku.color, lineWidth: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let status = importer.status {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        importer.chooseFiles()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .help("Import audio or video files and transcribe them (⌘O). You can also drop files on the list.")
                }
            }
    }
}

extension View {
    /// Import of audio and video files into the library: drop target, toolbar button and progress.
    func importDropTarget() -> some View {
        modifier(ImportDropTarget())
    }
}
