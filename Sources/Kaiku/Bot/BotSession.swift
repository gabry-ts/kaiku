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
    /// Posted in the meeting chat on joining; empty for none.
    let chatMessage: String
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

    /// - Parameter message: this trip's chat message; nil or blank uses the one in Settings.
    init(link: MeetingLink, title: String, start: Date?, message: String? = nil) {
        self.link = link
        self.title = title
        let custom = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        chatMessage = custom.isEmpty ? AppSettings.botChatMessage : custom
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
        var chatTries = chatMessage.isEmpty || !platform.hasChat ? 3 : 0
        var stepFailures = 0
        // Why the bot left, kept in the log; `unexpected` also tells you.
        var leftBecause = "stopped from the menu"
        var unexpected = false
        var lastPhase: MeetingPageState.Phase?
        // Since when the call screen is gone, after having been in the call.
        var outOfCallSince: Date?
        loop: while !stopRequested && !Task.isCancelled {
            guard chrome.isRunning else {
                leftBecause = "Google Chrome closed (\(chrome.exitDescription))"
                unexpected = true
                failure = callStart == nil ? "Google Chrome closed" : nil
                break
            }
            if chrome.devTools.pageCrashed {
                leftBecause = "the meeting page crashed in Google Chrome"
                unexpected = true
                failure = callStart == nil ? "The meeting page crashed" : nil
                break
            }
            let state: MeetingPageState?
            do {
                state = try await platform.step(chrome.devTools, name: AppSettings.botName, camera: photo != nil)
                stepFailures = 0
            } catch {
                Log.app.error("Meeting bot page step failed: \(error.diagnosticDescription, privacy: .public)")
                state = nil
                stepFailures += 1
                // The connection to the page dropped: connect to it again.
                if stepFailures >= 2 && chrome.isRunning {
                    do { try await chrome.reconnect() } catch {
                        Log.app.error("Meeting bot reconnect failed: \(error.diagnosticDescription, privacy: .public)")
                    }
                    stepFailures = 0
                }
            }
            // What the page said at every change, so an unknown end screen can be taught later.
            if let seen = state?.phase, seen != lastPhase {
                lastPhase = seen
                let text = await platform.snippet(chrome.devTools)
                Log.app.notice("Meeting bot page is \(seen.rawValue, privacy: .public): \(text, privacy: .public)")
            }
            if callStart != nil && state?.phase != .inCall && state?.phase != .ended {
                // Back from the call to a screen not known as an end: give it a minute.
                let since = outOfCallSince ?? Date()
                outOfCallSince = since
                if Date().timeIntervalSince(since) > 60 {
                    leftBecause = "the call screen was gone for a minute"
                    unexpected = true
                    break loop
                }
            }
            switch state?.phase {
            case .joining?, nil:
                if callStart == nil && Date().timeIntervalSince(joinStart) > Double(AppSettings.botLobbyMinutes) * 60 {
                    failure = "Nobody let the bot in after \(AppSettings.botLobbyMinutes) minutes."
                    break loop
                }
            case .lobby?:
                if callStart == nil { phase = .lobby }
                if callStart == nil && Date().timeIntervalSince(joinStart) > Double(AppSettings.botLobbyMinutes) * 60 {
                    failure = "Nobody let the bot in after \(AppSettings.botLobbyMinutes) minutes."
                    break loop
                }
            case .inCall?:
                outOfCallSince = nil
                let now = Date()
                if callStart == nil {
                    callStart = now
                    phase = .inCall(since: now)
                    do { try createFolder(date: now) } catch {
                        failure = "The call could not be saved: \(error.diagnosticDescription)"
                        break loop
                    }
                }
                updateAudio(pid: chrome.pid)
                // A few seconds in, once the call screen has settled; a few tries at most.
                if chatTries < 3, let start = callStart, now.timeIntervalSince(start) > 5 {
                    chatTries += 1
                    if await platform.sendChat(chrome.devTools, chatMessage) { chatTries = 3 }
                }
                if let people = state?.participants {
                    if people > 1 { lastWithOthers = now }
                    if AppSettings.botLeaveWhenAlone, let last = lastWithOthers, now.timeIntervalSince(last) > 120 {
                        leftBecause = "everyone else left (the page counted \(people))"
                        break loop
                    }
                }
                if let start = callStart, now.timeIntervalSince(start) > Double(AppSettings.botMaxMinutes) * 60 {
                    leftBecause = "the longest call setting was reached"
                    break loop
                }
            case .ended?:
                leftBecause = "\(link.platform.name) showed: \(state?.detail ?? "the call ended")"
                unexpected = true
                if callStart == nil { failure = state?.detail ?? "The bot could not join the meeting." }
                break loop
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if let failure { leftBecause = failure }
        Log.app.notice("Meeting bot left \(self.link.platform.name, privacy: .public) after \(Int(callStart.map { Date().timeIntervalSince($0) } ?? 0))s: \(leftBecause, privacy: .public)")
        if unexpected && callStart != nil {
            Notifier.shared.post(.problem, title: "Meeting bot left the call", body: leftBecause, folderPath: folder?.url.path)
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
            if await AppState.shared.discardIfTooShort(folder) { break }
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

    /// Snapshots only: shows the trip in a state, without running it.
    func setPreview(phase: Phase, listening: Bool = false) {
        self.phase = phase
        self.listening = listening
    }

    /// Quitting Kaiku: stop at once. The call is recovered at the next launch.
    func kill() {
        task?.cancel()
        tap?.stop()
        chrome?.quit()
    }
}
