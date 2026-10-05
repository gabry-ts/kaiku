import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Copies the shared audio and video files into the App Group inbox; the app imports them when it opens.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task {
            var added = 0
            for provider in providers where await Self.store(provider) { added += 1 }
            model.result = added > 0 ? .done : .failed
            try? await Task.sleep(for: .seconds(1.2))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Copies one file into <group>/Imports/<uuid>/ next to a meta.json with its creation date.
    private static func store(_ provider: NSItemProvider) async -> Bool {
        guard let type = [UTType.audio, .movie].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { return false }
        return await withCheckedContinuation { continuation in
            // The file only exists during the handler, so it is copied there.
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: false) }
                do {
                    let folder = AppGroup.imports.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
                    let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                    let meta = try JSONEncoder().encode(["createdAt": created.timeIntervalSince1970])
                    try meta.write(to: folder.appendingPathComponent("meta.json"))
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

@MainActor
private final class ShareModel: ObservableObject {
    enum Result { case working, done, failed }
    @Published var result = Result.working
}

private struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        VStack(spacing: 12) {
            switch model.result {
            case .working:
                ProgressView()
                Text("Adding to Kaiku…")
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Added to Kaiku. Open Kaiku to transcribe.").multilineTextAlignment(.center)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text("Only audio and video files can be added.").multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
