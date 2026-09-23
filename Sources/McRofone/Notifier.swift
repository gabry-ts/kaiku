import AppKit
import UserNotifications

/// Local notifications. Clicking one that belongs to a recording (`userInfo["folder"]`)
/// opens the Library with that recording selected. "Transcript ready" notifications
/// also offer Open Transcript / Copy Transcript actions.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let transcriptCategory = "transcript"
    private static let recoveredCategory = "recovered"
    private static let callDetectedCategory = "callDetected"
    private static let callEndedCategory = "callEnded"
    private static let openAction = "open"
    private static let copyAction = "copy"
    private static let transcribeAction = "transcribe"
    private static let recordAction = "record"
    private static let dismissAction = "dismiss"
    private static let stopAction = "stop"

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open Transcript", options: [.foreground])
        let copy = UNNotificationAction(identifier: Self.copyAction, title: "Copy Transcript", options: [])
        let transcribe = UNNotificationAction(identifier: Self.transcribeAction, title: "Transcribe", options: [])
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: Self.dismissAction, title: "Dismiss", options: [])
        let stop = UNNotificationAction(identifier: Self.stopAction, title: "Stop Recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.transcriptCategory, actions: [open, copy], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.recoveredCategory, actions: [transcribe, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.callDetectedCategory, actions: [record, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.callEndedCategory, actions: [stop, dismiss], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in Permissions.shared.refresh() }
        }
    }

    /// - Parameter folderPath: recording folder to show in the Library when clicked.
    func post(title: String, body: String, folderPath: String?, force: Bool = false) {
        send(title: title, body: body, userInfo: folderPath.map { ["folder": $0] } ?? [:], category: nil, force: force)
    }

    func postTranscriptReady(title: String, folderPath: String) {
        let folder = (folderPath as NSString).abbreviatingWithTildeInPath
        send(title: "Transcript ready", body: "\(title)\nSaved in \(folder)",
             userInfo: ["folder": folderPath], category: Self.transcriptCategory)
    }

    func postRecovered(title: String, folderPath: String) {
        send(title: "Recovered call \"\(title)\"", body: "The recording was interrupted, but the audio is safe. Transcribe it now?",
             userInfo: ["folder": folderPath], category: Self.recoveredCategory, force: true)
    }

    /// "Call detected in Zoom. Record?" Clicking or Record opens the title prompt.
    func postCallDetected(app: String) {
        send(title: "Call detected in \(app)", body: "Record it?", userInfo: ["kind": "callDetected", "app": app],
             category: Self.callDetectedCategory, force: true, id: "callDetected")
    }

    func postCallEnded(app: String, autoStopSeconds: Int) {
        let body = autoStopSeconds > 0
            ? "\(app) stopped using the microphone. Recording stops in \(autoStopSeconds) s unless the call resumes."
            : "\(app) stopped using the microphone. Stop recording?"
        send(title: "Call seems to have ended", body: body, userInfo: ["kind": "callEnded"],
             category: Self.callEndedCategory, force: true, id: "callEnded")
    }

    /// - Parameter force: sent even when "notify when a transcript is ready" is off,
    ///   because the notification asks for a decision.
    private func send(title: String, body: String, userInfo: [String: String], category: String?,
                      force: Bool = false, id: String = UUID().uuidString) {
        guard AppSettings.notificationsEnabled || force else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let path = info["folder"] as? String
        let kind = info["kind"] as? String
        let app = info["app"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch (kind, action) {
                case ("callDetected", Self.recordAction), ("callDetected", UNNotificationDefaultActionIdentifier):
                    AppState.shared.requestStart(app: app)
                case ("callEnded", Self.stopAction):
                    AppState.shared.stopRecording()
                default: break
                }
            }
            guard let path, action != Self.dismissAction else { return }
            let folder = RecordingFolder(url: URL(fileURLWithPath: path, isDirectory: true))
            if action == Self.copyAction {
                McRofone.copy(folder)
            } else if action == Self.transcribeAction {
                MainActor.assumeIsolated {
                    AppState.shared.transcribe(folder: folder, provider: AppSettings.provider)
                }
            } else {
                MainActor.assumeIsolated { AppState.shared.openInLibrary(folder) }
            }
        }
        completionHandler()
    }
}
