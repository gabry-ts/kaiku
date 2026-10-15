import CoreAudio
import Foundation
import KaikuCore
import os

/// One trip of the meeting bot: waits for the start time if scheduled, joins the call in
/// headless Chrome, records its audio (muted on the speakers unless you listen in), leaves
/// when asked, alone, or too long, then hands the call to transcription.
@MainActor
final class BotSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case scheduled(Date)
        case joining
        case lobby
        case inCall(since: Date)
        case leaving
        case finished
        case failed(String)
    }

    let id = UUID()
    let link: MeetingLink
    let title: String
    @Published private(set) var phase: Phase
    @Published private(set) var listening = false

    /// The bot's audio processes, left out of every other tap.
    private(set) var audioProcesses: [AudioObjectID] = []
    var onProcessesChanged: (() -> Void)?
    var onFinished: (() -> Void)?

    private var chrome: ChromeLauncher?
    private var tap: SystemAudioTap?
    private let tapped = OSAllocatedUnfairLock<[AudioObjectID]>(initialState: [])
    private var folder: RecordingFolder?
    private var task: Task<Void, Never>?
    private var stopRequested = false

    init(link: MeetingLink, title: String, start: Date?) {
        self.link = link
        self.title = title
        phase = start.map { $0.timeIntervalSinceNow > 60 ? .scheduled($0) : .joining } ?? .joining
    }

    var isActive: Bool {
        switch phase {
        case .finished, .failed: return false
        default: return true
        }
    }

    func begin() {
        task = Task { await run() }
    }

    /// Cancels a scheduled trip, or leaves the call and keeps what was recorded.
    func stop() {
        if case .scheduled = phase {
            task?.cancel()
            phase = .finished
            onFinished?()
            return
        }
        stopRequested = true
        if case .inCall = phase { phase = .leaving }
    }

    /// Plays the meeting on the speakers too, without stopping the recording.
    func setListening(_ on: Bool) {
        listening = on
        tap?.setMuted(!on)
    }

    // MARK: Run

    private func run() async {
        if case .scheduled(let start) = phase {
            // A little early, to be in the lobby when the host arrives.
            let wait = start.timeIntervalSinceNow - 30
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            phase = .joining
        }
        let platform = MeetingPlatform(platform: link.platform)
        let photo = AppSettings.botPhoto
        let chrome: ChromeLauncher
        do {
            chrome = try await ChromeLauncher.launch(url: platform.joinURL(link), photo: photo)
        } catch {
            return fail("The meeting bot could not start: \(error.diagnosticDescription)")
        }
        self.chrome = chrome
        Log.app.info("Meeting bot joining \(self.link.platform.name, privacy: .public)")

        let joinStart = Date()
        var callStart: Date?
        var lastWithOthers: Date?
        var failure: String?
        loop: while !stopRequested && !Task.isCancelled {
            guard chrome.isRunning else { failure = callStart == nil ? "Google Chrome closed" : nil; break }
            let state: MeetingPageState?
            do {
                state = try await platform.step(chrome.devTools, name: AppSettings.botName, camera: photo != nil)
            } catch {
                Log.app.error("Meeting bot page step failed: \(error.diagnosticDescription, privacy: .public)")
                state = nil
            }
            switch state?.phase {
            case .joining?, nil:
                if callStart == nil && Date().timeIntervalSince(joinStart) > Double(AppSettings.botLobbyMinutes) * 60 {
                    failure = "Nobody let the bot in after \(AppSettings.botLobbyMinutes) minutes."
                    break loop
                }
            case .lobby?:
                phase = .lobby
                if Date().timeIntervalSince(joinStart) > Double(AppSettings.botLobbyMinutes) * 60 {
                    failure = "Nobody let the bot in after \(AppSettings.botLobbyMinutes) minutes."
                    break loop
                }
            case .inCall?:
                let now = Date()
                if callStart == nil {
                    callStart = now
                    phase = .inCall(since: now)
                    do { try createFolder(date: now) } catch {
                        failure = "The call could not be saved: \(error.diagnosticDescription)"
                        break loop
                    }
                    let message = AppSettings.botChatMessage
                    if !message.isEmpty { await platform.sendChat(chrome.devTools, message) }
                }
                updateAudio(pid: chrome.pid)
                if let people = state?.participants {
                    if people > 1 { lastWithOthers = now }
                    if AppSettings.botLeaveWhenAlone, let last = lastWithOthers, now.timeIntervalSince(last) > 120 {
                        Log.app.info("Meeting bot leaving: alone in the call")
                        break loop
                    }
                }
                if let start = callStart, now.timeIntervalSince(start) > Double(AppSettings.botMaxMinutes) * 60 {
                    Log.app.info("Meeting bot leaving: longest call reached")
                    break loop
                }
            case .ended?:
                if callStart == nil { failure = state?.detail ?? "The bot could not join the meeting." }
                break loop
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if callStart != nil {
            phase = .leaving
            await platform.leave(chrome.devTools)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        await finish(duration: callStart.map { Date().timeIntervalSince($0) } ?? 0, failure: failure)
    }

    private func createFolder(date: Date) throws {
        let folder = try AppState.shared.makeFolder(date: date, title: title)
        try folder.saveMeta(RecordingMeta(
            title: title, date: date, durationSeconds: 0, language: AppSettings.language,
            status: .recording, source: link.platform.name, sourceApp: "Kaiku meeting bot"))
        self.folder = folder
    }

    /// Starts the tap once Chrome plays audio, and follows its audio processes after.
    private func updateAudio(pid: pid_t) {
        guard let folder else { return }
        let processes = SystemAudioTap.audioProcesses(descendantsOf: pid)
        guard !processes.isEmpty, processes != audioProcesses else { return }
        audioProcesses = processes
        tapped.withLock { $0 = processes }
        onProcessesChanged?()
        if let tap {
            tap.refresh()
            return
        }
        let gate = PauseGate()
        gate.markOrigin()
        let tapped = tapped
        let tap = SystemAudioTap(processes: { tapped.withLock { $0 } }, muted: !listening)
        do {
            try tap.start(writer: TrackWriter(url: folder.systemRawURL, gate: gate))
            self.tap = tap
            Log.audio.info("Meeting bot audio tap started")
        } catch {
            Log.audio.error("Meeting bot audio tap failed: \(error.diagnosticDescription, privacy: .public)")
        }
    }

    private func finish(duration: Double, failure: String?) async {
        tap?.stop()
        tap = nil
        chrome?.quit()
        chrome = nil
        listening = false
        audioProcesses = []
        onProcessesChanged?()
        defer { onFinished?() }

        guard let folder else {
            if let failure { fail(failure) } else { phase = .finished }
            return
        }
        let result = await Task.detached { Result { try AudioFinalizer.finalize(folder) } }.value
        switch result {
        case .success(let seconds?) where seconds > 0:
            folder.updateMeta { $0.durationSeconds = duration }
            phase = .finished
            AppState.shared.transcribe(folder: folder, provider: AppSettings.provider, summarize: AppSettings.botSummarize ? true : nil)
        case .success:
            let message = "The meeting bot recorded no audio."
            folder.updateMeta { $0.status = .error; $0.error = message }
            fail(message, folder: folder)
        case .failure(let error):
            folder.updateMeta { $0.status = .error; $0.error = error.diagnosticDescription }
            fail(error.diagnosticDescription, folder: folder)
        }
        AppState.shared.reloadLibrary()
    }

    private func fail(_ message: String, folder: RecordingFolder? = nil) {
        Log.app.error("Meeting bot: \(message, privacy: .public)")
        phase = .failed(message)
        Notifier.shared.post(.problem, title: "Meeting bot", body: message, folderPath: folder?.url.path)
    }

    /// Quitting Kaiku: stop at once. The call is recovered at the next launch.
    func kill() {
        task?.cancel()
        tap?.stop()
        chrome?.quit()
    }
}
