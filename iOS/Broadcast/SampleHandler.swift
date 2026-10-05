import Foundation
import ReplayKit

/// Records the system audio and the microphone of a screen broadcast into <group>/Broadcasts/<id>/.
/// The app imports the folder once the broadcast finishes.
class SampleHandler: RPBroadcastSampleHandler {
    private var folder: URL?
    private var system: BroadcastWriter?
    private var mic: BroadcastWriter?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let folder = AppGroup.broadcasts.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        system = BroadcastWriter(folder: folder, name: "system")
        mic = BroadcastWriter(folder: folder, name: "mic")
        write(["date": Date().timeIntervalSince1970], to: "started.json")
        AppGroup.post(AppGroup.Notification.broadcastStarted)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp: system?.append(sampleBuffer)
        case .audioMic: mic?.append(sampleBuffer)
        default: break
        }
    }

    override func broadcastFinished() {
        system?.close()
        mic?.close()
        write(["endDate": Date().timeIntervalSince1970], to: "done.json")
        AppGroup.post(AppGroup.Notification.broadcastFinished)
    }

    private func write(_ values: [String: Double], to name: String) {
        guard let folder, let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: folder.appendingPathComponent(name))
    }
}
