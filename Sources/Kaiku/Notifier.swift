import AppKit
import UserNotifications
import KaikuCore

/// Local notifications. Clicking one that belongs to a recording (`userInfo["folder"]`)
/// opens the Library with that recording selected. "Transcript ready" notifications
/// also offer Open Transcript / Copy Transcript actions. Every notification has a kind,
/// which Settings > Notifications can switch off or silence.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let transcriptCategory = "transcript"
    private static let recoveredCategory = "recovered"
    private static let callDetectedCategory = "callDetected"
    private static let callEndedCategory = "callEnded"
    private static let callDetectedNewCategory = "callDetectedNew"
    private static let newSourceCategory = "newSource"
    private static let openAction = "open"
    private static let copyAction = "copy"
    private static let transcribeAction = "transcribe"
    private static let recordAction = "record"
    private static let dismissAction = "dismiss"
    private static let stopAction = "stop"
    private static let alwaysAction = "always"
    private static let neverAction = "never"

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open Transcript", options: [.foreground])
        let copy = UNNotificationAction(identifier: Self.copyAction, title: "Copy Transcript", options: [])
        let transcribe = UNNotificationAction(identifier: Self.transcribeAction, title: "Transcribe", options: [])
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: Self.dismissAction, title: "Dismiss", options: [])
        let stop = UNNotificationAction(identifier: Self.stopAction, title: "Stop Recording", options: [])
        let always = UNNotificationAction(identifier: Self.alwaysAction, title: "Always Record", options: [])
        let never = UNNotificationAction(identifier: Self.neverAction, title: "Never", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.transcriptCategory, actions: [open, copy], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.recoveredCategory, actions: [transcribe, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.callDetectedCategory, actions: [record, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.callEndedCategory, actions: [stop, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.callDetectedNewCategory, actions: [record, always, never], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.newSourceCategory, actions: [always, never], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in Permissions.shared.refresh() }
        }
    }

    /// - Parameter folderPath: recording folder to show in the Library when clicked.
    func post(_ kind: NotificationKind, title: String, body: String, folderPath: String?) {
        send(kind, title: title, body: body, userInfo: folderPath.map { ["folder": $0] } ?? [:], category: nil)
    }

    func postTranscriptReady(title: String, folderPath: String) {
        let folder = (folderPath as NSString).abbreviatingWithTildeInPath
        send(.transcriptReady, title: "Transcript ready", body: "\(title)\nSaved in \(folder)",
             userInfo: ["folder": folderPath], category: Self.transcriptCategory)
    }

    func postRecovered(title: String, folderPath: String) {
        send(.recovered, title: "Recovered call \"\(title)\"", body: "The recording was interrupted, but the audio is safe. Transcribe it now?",
             userInfo: ["folder": folderPath], category: Self.recoveredCategory)
    }

    /// "Call detected in Zoom. Record?" Clicking or Record opens the title prompt.
    /// A new source also offers Always Record / Never.
    func postCallDetected(_ call: DetectedCall, isNew: Bool) {
        send(.callDetected, title: isNew ? "New source: \(call.source)" : "Call detected in \(call.source)", body: "Record it?",
             userInfo: ["kind": "callDetected", "source": call.source, "app": call.app, "windowTitle": call.windowTitle ?? ""],
             category: isNew ? Self.callDetectedNewCategory : Self.callDetectedCategory, id: "callDetected")
    }

    /// Recording already started for a source never seen before: keep recording it, or never.
    func postNewSource(_ call: DetectedCall) {
        send(.newSource, title: "New source: \(call.source)", body: "Recording started. Always record calls from \(call.source)?",
             userInfo: ["kind": "newSource", "source": call.source, "app": call.app],
             category: Self.newSourceCategory, id: "newSource")
    }

    func postCallEnded(app: String, autoStopSeconds: Int) {
        let body = autoStopSeconds > 0
            ? "\(app) stopped using the microphone. Recording stops in \(autoStopSeconds) s unless the call resumes."
            : "\(app) stopped using the microphone. Stop recording?"
        send(.callEnded, title: "Call seems to have ended", body: body, userInfo: ["kind": "callEnded"],
             category: Self.callEndedCategory, id: "callEnded")
    }

    /// The one place a notification is posted from: a kind that is switched off is never
    /// posted, one with its sound off is posted silently.
    private func send(_ kind: NotificationKind, title: String, body: String, userInfo: [String: String],
                      category: String?, id: String = UUID().uuidString) {
        guard AppSettings.notificationShown(kind) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if AppSettings.notificationSound(kind) { content.sound = .default }
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
        let source = info["source"] as? String
        let windowTitle = (info["windowTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let call = source.map { DetectedCall(source: $0, app: info["app"] as? String ?? $0, windowTitle: windowTitle) }
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch (kind, action) {
                case ("callDetected", Self.recordAction), ("callDetected", UNNotificationDefaultActionIdentifier):
                    AppState.shared.requestStart(call: call)
                case ("callDetected", Self.alwaysAction):
                    if let source { AppState.shared.setRule(.always, for: source) }
                    AppState.shared.requestStart(call: call)
                case ("callDetected", Self.neverAction), ("newSource", Self.neverAction):
                    if let source { AppState.shared.setRule(.never, for: source) }
                case ("newSource", Self.alwaysAction):
                    if let source { AppState.shared.setRule(.always, for: source) }
                case ("callEnded", Self.stopAction):
                    AppState.shared.stopRecording()
                default: break
                }
            }
            guard let path, action != Self.dismissAction else { return }
            let folder = RecordingFolder(url: URL(fileURLWithPath: path, isDirectory: true))
            if action == Self.copyAction {
                Kaiku.copy(folder)
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
