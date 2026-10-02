import AppKit
import AVFoundation
import KaikuCore

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case recording(title: String, start: Date)
        case transcribing(title: String)
        case done(title: String)
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Bumped whenever recordings on disk change, so the library can reload.
    @Published private(set) var libraryVersion = 0
    /// Folders currently being transcribed.
    @Published private(set) var busyFolders: Set<String> = []
    /// Full text of the last error or warning, for "Show Error Details".
    @Published private(set) var lastErrorDetail: String?
    /// Running transcription per folder key, so it can be cancelled.
    private var jobs: [String: Task<Void, Never>] = [:]
    /// Human readable step per busy folder key, e.g. "Transcribing call audio (2 of 2)…".
    @Published private(set) var busyStage: [String: String] = [:]
    /// Animation frame for the menu bar glyph while transcribing.
    @Published private(set) var glyphFrame = 0
    /// Recording to select when the library opens.
    @Published var librarySelection: String?
    /// A call to show in the library and the moment to play, asked for by a chat citation.
    @Published var librarySeek: LibrarySeek?
    /// Set when a `kaiku://chat` URL asked for the chat; the library opens it and clears this.
    @Published var chatRequested = false
    /// True while the current recording is paused.
    @Published private(set) var isPaused = false
    /// Bookmarks of the current recording.
    @Published private(set) var bookmarks: [Bookmark] = []
    /// Calls saved after an interruption, offered for transcription in the panel.
    @Published private(set) var recoveredFolders: [RecordingFolder] = []
    /// Calendar event linked to the current recording.
    @Published private(set) var currentEvent: CalendarEventInfo?
    /// Microphone in use for the current recording.
    @Published private(set) var currentMic: AudioDevice?

    /// Live levels, kept separate so only views that show meters re-render at 12 Hz.
    let levels = Levels()

    /// The per-second clock, kept separate so only views that show elapsed time re-render each second.
    let tick = Tick()

    final class Tick: ObservableObject {
        @Published var now = Date()
    }

    final class Levels: ObservableObject {
        @Published var mic: Float = 0
        @Published var system: Float = 0
        @Published var hasMic = true
    }

    /// Live transcript of the current recording, kept separate like the levels.
    let live = LiveSession()

    /// The library chat, kept here so an answer goes on while the library is closed.
    let chat = ChatModel()

    /// Smart search: the passage index of the calls and its results.
    let semantic = SemanticSearchModel()

    private var levelTimer: Timer?
    private var glyphTimer: Timer?

    private var recorder: CallRecorder?
    private var currentFolder: RecordingFolder?
    /// The live session of the recording just stopped, while it hands over its last words.
    private var liveFinishing: Task<LiveSession.Outcome, Never>?
    /// The menu bar panel is open: the level meters run fast only while they can be seen.
    @Published var panelVisible = false {
        didSet {
            guard panelVisible != oldValue, let rec = recorder else { return }
            startLevelTimer(rec)
        }
    }
    /// A write error of the current recording was already shown.
    private var writeErrorShown = false
    private var ticker: Timer?
    private var clock: RecordingClock?
    private var routes: [OutputRoute] = []
    private var muteIntervals: [MuteInterval] = []
    private var cleanupTimer: Timer?
    /// Source of the current recording when it was started automatically.
    private var autoStartedSource: String?
    /// Fallback title given to the current auto-started recording, replaced if the
    /// call window gets a meaningful title soon after.
    private var autoFallbackTitle: String?
    /// Source of the call being recorded; nil for a manual recording.
    private(set) var currentCallSource: String?
    /// The microphone was picked in the panel, so it no longer follows the call's.
    private var micChosenByHand = false
    /// Microphone being switched to by following the call, while the switch runs.
    private var followingMicUID: String?
    /// Call microphone that couldn't be opened, not tried again during this recording.
    private var followFailedUID: String?
    /// Stops the current recording when it was clearly left running.
    private var recordingGuard = RecordingGuard()

    var isRecording: Bool { if case .recording = phase { return true } else { return false } }

    /// Recorded time of the current call (pauses excluded).
    var elapsed: TimeInterval {
        guard case .recording(_, let start) = phase else { return 0 }
        return (clock ?? RecordingClock(start: start)).recordedTime(at: tick.now)
    }

    /// The call the last error is about, nil when it is about no call (e.g. no mic access).
    @Published private(set) var errorFolder: RecordingFolder?

    var lastFolder: RecordingFolder? {
        guard let url = AppSettings.lastRecordingFolder,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return RecordingFolder(url: url)
    }

    // MARK: Recording

    /// Shows the title prompt, prefilled from the calendar event happening now if any,
    /// otherwise from the call that was detected.
    func requestStart(call: DetectedCall? = nil) {
        guard !isRecording else { return }
        let event = CalendarService.shared.currentEvent()
        let date = Date()
        let title = call.map { CallTitle.choose(eventTitle: event?.title, windowTitle: $0.windowTitle, source: $0.source, date: date) }
            ?? event?.title ?? Naming.defaultTitle(date: date)
        WindowManager.shared.showTitlePrompt(title: title, event: event, call: call)
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { requestStart() }
    }

    var currentTitle: String? {
        if case .recording(let t, _) = phase { return t }
        return nil
    }

    var anyBusy: Bool { !busyFolders.isEmpty }

    /// Brings up the Library (front-most), selecting `folder` if given.
    /// Works whether the window is already open or the app just launched.
    func openInLibrary(_ folder: RecordingFolder?) {
        libraryVersion += 1
        if let folder { librarySelection = folder.key }
        WindowManager.shared.showLibrary()
    }

    /// Selects `folder` in the library and plays it from `time` when given (a chat citation).
    func showInLibrary(_ folder: RecordingFolder, at time: Double?) {
        librarySelection = folder.key
        librarySeek = LibrarySeek(key: folder.key, time: time)
    }

    /// - Parameters:
    ///   - call: the detected call being recorded; nil for a manual recording.
    ///   - autoStarted: started by call detection; `fallbackTitle` is the title to replace
    ///     once the call window has a better one.
    func startRecording(title rawTitle: String, language rawLanguage: String, event: CalendarEventInfo? = nil,
                        tags rawTags: [String] = [], call: DetectedCall? = nil,
                        autoStarted: Bool = false, fallbackTitle: String? = nil) async {
        guard !isRecording else { return }
        let date = Date()
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Naming.defaultTitle(date: date) : rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = AppSettings.normalizedLanguage(rawLanguage)

        let micAllowed = AppSettings.microphone == AudioDevices.none ? true : await Self.ensureMicPermission()
        guard micAllowed else {
            fail("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.", folderPath: nil)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        // Another start may have won while the permission was asked.
        guard !isRecording else { return }

        do {
            let folder = try makeFolder(date: date, title: title)
            try folder.saveMeta(RecordingMeta(
                title: title, date: date, durationSeconds: 0, language: language,
                status: .recording, calendarEvent: event, tags: Tags.normalize(rawTags).nilIfEmpty,
                source: call?.source ?? CallSource.manual, sourceApp: call?.app))
            if !rawTags.isEmpty { AppSettings.defaults.set(Tags.normalize(rawTags), forKey: Keys.lastTags) }
            let micSetting = AppSettings.microphone
            let callMic = AppSettings.followCallMicrophone ? MeetingMonitor.shared.callMicrophone(source: call?.source) : nil
            let micDevice = callMic ?? AudioDevices.resolveMicrophone(setting: micSetting)
            if let callMic { Log.audio.info("Recording from the call's microphone: \(callMic.name, privacy: .public)") }
            if micDevice == nil && micSetting != AudioDevices.none {
                Log.audio.error("No usable microphone found; recording system audio only")
            }
            let rec = CallRecorder()
            routes = []
            rec.onRoute = { route, initial in
                DispatchQueue.main.async { AppState.shared.outputChanged(route, initial: initial) }
            }
            rec.onMicFallback = { lost, now in
                DispatchQueue.main.async { AppState.shared.micLost(lost, now: now) }
            }
            let liveEngine = AppSettings.liveEnabled ? AppSettings.liveEngine?.make() : nil
            if let liveEngine { rec.liveTap = LiveSession.tap(into: liveEngine) }
            // The clock starts with the tracks, not before the permission prompt.
            let started = Date()
            try rec.start(micURL: folder.micRawURL, systemURL: folder.systemRawURL, micDevice: micDevice)
            recorder = rec
            writeErrorShown = false
            currentFolder = folder
            clock = RecordingClock(start: started)
            muteIntervals = MicMuter.shared.isMuted ? [MuteInterval(start: 0)] : []
            if !muteIntervals.isEmpty { folder.updateMeta { $0.muteIntervals = AppState.shared.muteIntervals } }
            currentMic = rec.micDevice
            isPaused = false
            bookmarks = []
            currentEvent = event
            // Set together with the start, so a manual recording is never taken for an automatic one.
            autoStartedSource = autoStarted ? call?.source : nil
            autoFallbackTitle = autoStarted ? fallbackTitle : nil
            recordingGuard = RecordingGuard()
            currentCallSource = call?.source
            micChosenByHand = false
            followingMicUID = nil
            followFailedUID = nil
            AppSettings.lastRecordingFolder = folder.url
            phase = .recording(title: title, start: started)
            tick.now = started
            startTicker()
            startLevelTimer(rec)
            libraryVersion += 1
            Log.app.info("Recording started: \(folder.url.path, privacy: .public)")
            if !rec.warnings.isEmpty {
                let detail = rec.warnings.joined(separator: "\n")
                lastErrorDetail = "Recording started with problems:\n\n\(detail)"
                Notifier.shared.post(.problem, title: "Recording one track only", body: detail, folderPath: nil)
            }
            if let liveEngine {
                // The previous recording's live session may still be handing over its last
                // words; the engine queues the audio meanwhile.
                _ = await liveFinishing?.value
                if recorder === rec {
                    live.start(liveEngine, language: language) { AppState.shared.elapsed(at: Date()) }
                } else {
                    Task { await liveEngine.stop() }
                }
            }
        } catch {
            fail("Could not start recording. \(error.diagnosticDescription)", folderPath: nil)
        }
    }

    /// Stops the current recording and deletes it for good, without transcribing.
    func discardRecording() {
        guard isRecording, let rec = recorder, let folder = currentFolder else { return }
        recorder = nil
        endLive()
        stopTicker()
        stopLevelTimer()
        currentFolder = nil
        clock = nil
        currentMic = nil
        isPaused = false
        currentEvent = nil
        autoStartedSource = nil
        bookmarks = []
        phase = .idle
        Task {
            await Task.detached { rec.stop() }.value
            do {
                try FileManager.default.removeItem(at: folder.url)
                Log.app.info("Recording discarded: \(folder.url.path, privacy: .public)")
            } catch {
                Log.app.error("Could not delete discarded recording: \(error.localizedDescription, privacy: .public)")
            }
            if let last = AppSettings.lastRecordingFolder, RecordingFolder(url: last).key == folder.key {
                AppSettings.lastRecordingFolder = nil
            }
            libraryVersion += 1
        }
    }

    /// - Parameter keepUntil: recorded time after which the audio is dropped, e.g. the
    ///   silence at the end of a recording stopped for silence.
    func stopRecording(keepUntil: Double? = nil) {
        guard case .recording(let title, _) = phase, let rec = recorder, let folder = currentFolder else { return }
        recorder = nil
        stopTicker()
        stopLevelTimer()
        let stopDate = Date()
        closeClock(at: stopDate)
        let duration = min(elapsed(at: stopDate), keepUntil ?? .infinity)
        phase = .transcribing(title: title)
        busyFolders.insert(folder.key)
        busyStage[folder.key] = "Saving audio…"
        updateGlyphTimer()
        // Cleared now: a new recording can start while this one is still being saved.
        currentFolder = nil
        clock = nil
        currentMic = nil
        isPaused = false
        currentEvent = nil
        let finishing = Task { () -> LiveSession.Outcome in
            let heard = await live.finish()
            WindowManager.shared.close("live")
            return heard
        }
        liveFinishing = finishing
        Task {
            let result = await Task.detached { () -> Result<Double?, Error> in
                rec.stop()
                return Result { try AudioFinalizer.finalize(folder, maxSeconds: keepUntil) }
            }.value
            let heard = await finishing.value
            if liveFinishing == finishing { liveFinishing = nil }
            if let summary = heard.summary {
                // Kept apart from summary.md, which is written after transcription.
                try? ("## Live summary\n\n" + summary + "\n").write(to: folder.liveSummaryURL, atomically: true, encoding: .utf8)
            }
            finishBusy(folder)
            if !isRecording { phase = .idle }
            switch result {
            case .success:
                folder.updateMeta { $0.durationSeconds = duration }
                // The live text is only kept when asked for and when none of it is missing.
                let keep = AppSettings.liveAfterCall == .transcript && heard.complete && !heard.transcript.finals.isEmpty
                transcribe(folder: folder, provider: AppSettings.provider, live: keep ? heard.transcript : nil)
            case .failure(let error):
                folder.updateMeta {
                    $0.durationSeconds = duration
                    $0.status = .error
                    $0.error = error.diagnosticDescription
                }
                fail("Could not save \"\(title)\". \(error.diagnosticDescription)", folderPath: folder.url.path)
            }
        }
    }

    /// Called on quit: closes the crash-safe files so nothing is lost. The call is
    /// left in "recording" state and converted by recovery on the next launch.
    func finalizeOnQuit() {
        guard isRecording, let rec = recorder, let folder = currentFolder else { return }
        rec.stop()
        endLive()
        stopTicker()
        stopLevelTimer()
        let date = Date()
        closeClock(at: date)
        let duration = elapsed(at: date)
        phase = .idle
        folder.updateMeta { $0.durationSeconds = duration }
    }

    /// Drops the live transcript and closes its window.
    private func endLive() {
        live.cancel()
        WindowManager.shared.close("live")
    }

    // MARK: Device changes

    /// Mute intervals are kept in meta.json, for information.
    func microphonesMuted(_ muted: Bool) {
        guard isRecording, let folder = currentFolder else { return }
        let t = elapsed(at: Date())
        if muted {
            muteIntervals.append(MuteInterval(start: t))
        } else if !muteIntervals.isEmpty, muteIntervals[muteIntervals.count - 1].end == nil {
            muteIntervals[muteIntervals.count - 1].end = t
        }
        let all = muteIntervals
        folder.updateMeta { $0.muteIntervals = all }
    }

    /// The call audio moved to another output (or the first one at start).
    private func outputChanged(_ route: SystemAudioTap.Route, initial: Bool) {
        guard isRecording, let folder = currentFolder else { return }
        let t = elapsed(at: Date())
        if !routes.isEmpty, routes[routes.count - 1].end == nil { routes[routes.count - 1].end = t }
        routes.append(OutputRoute(start: routes.isEmpty ? 0 : t, deviceName: route.name, isHeadphones: route.isHeadphones))
        let all = routes
        folder.updateMeta { $0.outputRoutes = all }
        Log.app.info("Output route: \(route.name, privacy: .public) (headphones: \(route.isHeadphones))")
        if !initial {
            Notifier.shared.post(.deviceChanged, title: "Audio output changed", body: "Still recording, now from \(route.name).", folderPath: nil)
        }
    }

    private func micLost(_ lost: String, now: AudioDevice?) {
        guard isRecording else { return }
        currentMic = now
        if let now {
            Notifier.shared.post(.deviceChanged, title: "Microphone disconnected", body: "Switched to \(now.name). Still recording.", folderPath: nil)
        } else {
            levels.hasMic = false
            lastErrorDetail = "\(lost) was disconnected and no other microphone is available. Only the call audio is being recorded."
            Notifier.shared.post(.deviceChanged, title: "Microphone disconnected", body: "No other microphone found. Recording the call audio only.", folderPath: nil)
        }
    }

    /// Mic picker in the panel. Uses the same hot-swap as the automatic fallback.
    func switchMicrophone(to device: AudioDevice) {
        micChosenByHand = true
        swapMicrophone(to: device)
    }

    /// The call app now records from `device`: record from it too, unless a microphone
    /// was picked by hand during this recording.
    func followCallMicrophone(_ device: AudioDevice) {
        guard isRecording, !micChosenByHand, followingMicUID == nil, device.uid != currentMic?.uid,
              device.uid != followFailedUID else { return }
        followingMicUID = device.uid
        Log.audio.info("Following the call's microphone: \(device.name, privacy: .public)")
        swapMicrophone(to: device) { ok in
            AppState.shared.followingMicUID = nil
            if !ok { AppState.shared.followFailedUID = device.uid }
            if ok {
                Notifier.shared.post(.deviceChanged, title: "Microphone changed", body: "Now recording from \(device.name), like your call.", folderPath: nil)
            }
        }
    }

    private func swapMicrophone(to device: AudioDevice, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let rec = recorder else { return done(false) }
        Task {
            let result = await Task.detached { Result { try rec.switchMicrophone(to: device) } }.value
            switch result {
            case .success:
                currentMic = device
                done(true)
            case .failure(let error):
                fail("Couldn't switch to \(device.name): \(error.diagnosticDescription)", folderPath: nil)
                done(false)
            }
        }
    }

    // MARK: Pause and bookmarks

    var canPause: Bool { isRecording }

    func togglePause() {
        guard isRecording, var c = clock, let rec = recorder, let folder = currentFolder else { return }
        let date = Date()
        if c.isPaused { c.resume(at: date) } else { c.pause(at: date) }
        clock = c
        isPaused = c.isPaused
        rec.setPaused(c.isPaused)
        tick.now = date
        folder.updateMeta {
            $0.pauses = c.pauses
            $0.status = c.isPaused ? .paused : .recording
        }
        Log.app.info("Recording \(c.isPaused ? "paused" : "resumed", privacy: .public)")
    }

    /// Adds a bookmark at the current audio position, right away. The label can be added later.
    @discardableResult
    func addBookmark(label: String = "") -> Bookmark? {
        guard isRecording, let c = clock, let folder = currentFolder else { return nil }
        let b = Bookmark(time: c.recordedTime(at: Date()), label: label)
        bookmarks.append(b)
        let all = bookmarks
        folder.updateMeta { $0.bookmarks = all }
        NSSound(named: "Tink")?.play()
        return b
    }

    /// Changes a bookmark label during the recording.
    func renameCurrentBookmark(_ id: UUID, to label: String) {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }), let folder = currentFolder else { return }
        bookmarks[i].label = label
        let all = bookmarks
        folder.updateMeta { $0.bookmarks = all }
    }

    /// Edits or removes (label nil) a bookmark of a saved call and refreshes transcript.md.
    func updateBookmark(_ folder: RecordingFolder, id: UUID, label: String?) {
        guard var meta = folder.loadMeta(), var list = meta.bookmarks, let i = list.firstIndex(where: { $0.id == id }) else { return }
        if let label { list[i].label = label.trimmingCharacters(in: .whitespacesAndNewlines) } else { list.remove(at: i) }
        meta.bookmarks = list.isEmpty ? nil : list
        try? folder.saveMeta(meta)
        if let raw = folder.loadSegments() { _ = try? TranscriptWriter.write(folder: folder, meta: meta, rawSegments: raw) }
        libraryVersion += 1
    }

    private func elapsed(at date: Date) -> Double { clock?.recordedTime(at: date) ?? 0 }

    /// Ends an open pause and saves pauses and bookmarks.
    private func closeClock(at date: Date) {
        guard var c = clock else { return }
        c.resume(at: date)
        clock = c
        recorder?.setPaused(false)
        let all = bookmarks
        if !routes.isEmpty, routes[routes.count - 1].end == nil { routes[routes.count - 1].end = c.recordedTime(at: date) }
        let allRoutes = routes
        if !muteIntervals.isEmpty, muteIntervals[muteIntervals.count - 1].end == nil {
            muteIntervals[muteIntervals.count - 1].end = c.recordedTime(at: date)
        }
        let mutes = muteIntervals
        currentFolder?.updateMeta {
            $0.muteIntervals = mutes.isEmpty ? nil : mutes
            $0.outputRoutes = allRoutes.isEmpty ? nil : allRoutes
            $0.pauses = c.pauses.isEmpty ? nil : c.pauses
            $0.bookmarks = all.isEmpty ? nil : all
            if $0.status == .paused { $0.status = .recording }
        }
    }

    // MARK: Transcription

    /// Transcribes again the call the last error is about.
    func retryFailed() {
        guard let folder = errorFolder, FileManager.default.fileExists(atPath: folder.url.path) else { return }
        transcribe(folder: folder, provider: AppSettings.provider)
    }

    /// - Parameter live: the text heard while recording, saved as the transcript instead
    ///   of running the provider. If saving it fails, the provider runs as usual.
    func transcribe(folder: RecordingFolder, provider: ProviderKind, live: LiveTranscript? = nil) {
        guard !busyFolders.contains(folder.key) else { return }
        let title = folder.loadMeta()?.title ?? folder.url.lastPathComponent
        busyFolders.insert(folder.key)
        busyStage[folder.key] = "Starting…"
        if !isRecording { phase = .transcribing(title: title) }
        libraryVersion += 1
        updateGlyphTimer()

        let task = Task {
            do {
                var saved = false
                if let live, let engine = AppSettings.liveEngine {
                    busyStage[folder.key] = "Saving the live transcript…"
                    do {
                        try await TranscriptionJob.saveLive(live, folder: folder, engine: engine)
                        saved = true
                    } catch {
                        Log.transcription.error("Live transcript not saved, transcribing instead: \(error.diagnosticDescription, privacy: .public)")
                    }
                }
                if !saved {
                    try await TranscriptionJob.run(folder: folder, providerKind: provider) { [weak self] stage in
                        self?.busyStage[folder.key] = stage
                    }
                }
                try Task.checkCancellation()
                recoveredFolders.removeAll { $0.key == folder.key }
                if AppSettings.summaryEnabled {
                    busyStage[folder.key] = "Writing summary…"
                    do { try await SummaryJob.run(folder: folder) } catch {
                        lastErrorDetail = error.localizedDescription
                        Notifier.shared.post(.problem, title: "Summary failed", body: error.localizedDescription, folderPath: folder.url.path)
                    }
                }
                try Task.checkCancellation()
                finishBusy(folder)
                semantic.indexPending()
                if !isRecording { phase = .done(title: title) }
                Notifier.shared.postTranscriptReady(title: title, folderPath: folder.url.path)
                if AppSettings.webhookEnabled { await sendWebhook(folder) }
            } catch {
                // cancelTranscription has already cleaned up.
                if Task.isCancelled { return }
                finishBusy(folder)
                fail("Transcription failed for \"\(title)\": \(error.diagnosticDescription)", folderPath: folder.url.path)
            }
        }
        jobs[folder.key] = task
    }

    /// Stops a running transcription: no summary and no webhook follow. The call stays
    /// in the library, ready to be transcribed again or deleted.
    func cancelTranscription(_ folder: RecordingFolder) {
        guard let task = jobs[folder.key] else { return }
        task.cancel()
        finishBusy(folder)
        // Cancelling while summarizing keeps the finished transcript.
        if folder.loadMeta()?.status == .transcribing {
            folder.updateMeta {
                $0.status = .error
                $0.error = TranscriptionJob.cancelledMessage
            }
        }
        if case .transcribing = phase, !anyBusy { phase = .idle }
        Log.transcription.info("Transcription cancelled: \(folder.url.lastPathComponent, privacy: .public)")
    }

    func canCancelTranscription(_ folder: RecordingFolder) -> Bool { jobs[folder.key] != nil }

    /// Generates (or regenerates) summary.md for a call.
    func generateSummary(_ folder: RecordingFolder) async throws {
        guard !busyFolders.contains(folder.key) else { return }
        busyFolders.insert(folder.key)
        busyStage[folder.key] = "Writing summary…"
        libraryVersion += 1
        updateGlyphTimer()
        defer { finishBusy(folder) }
        try await SummaryJob.run(folder: folder)
    }

    // MARK: Recovery and storage

    /// Converts calls interrupted by a crash or quit and offers to transcribe them.
    func recoverOnLaunch() {
        let base = AppSettings.baseFolder
        let skip = currentFolder?.key
        let busy = busyFolders
        Task {
            let outcomes = await Task.detached { Recovery.recoverAll(base: base, skip: skip, busy: busy) }.value
            libraryVersion += 1
            guard !outcomes.isEmpty else { return }
            for o in outcomes where o.recovered {
                recoveredFolders.append(o.folder)
                Notifier.shared.postRecovered(title: o.title, folderPath: o.folder.url.path)
            }
        }
    }

    /// The recordings folder was changed in Settings.
    func baseFolderChanged() {
        libraryVersion += 1
        recoverOnLaunch()
    }

    func dismissRecovered(_ folder: RecordingFolder) {
        recoveredFolders.removeAll { $0.key == folder.key }
    }

    /// Runs the "delete old audio" cleanup at launch and then about once a day.
    func startAutoCleanup() {
        runAutoCleanupIfDue()
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in AppState.shared.runAutoCleanupIfDue() }
        }
    }

    private func runAutoCleanupIfDue() {
        guard AppSettings.autoCleanupEnabled else { return }
        let last = AppSettings.defaults.object(forKey: Keys.lastAutoCleanup) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 23 * 3600 else { return }
        AppSettings.defaults.set(Date(), forKey: Keys.lastAutoCleanup)
        let targets = cleanupTargets(days: AppSettings.autoCleanupDays)
        guard !targets.isEmpty else { return }
        let (count, bytes) = cleanUpAudio(targets)
        Log.app.info("Auto cleanup moved audio of \(count) calls to the Trash")
        if count > 0 {
            Notifier.shared.post(.cleanup, title: "Old audio moved to the Trash",
                                 body: "\(count) call\(count == 1 ? "" : "s"), \(Storage.format(bytes)). Transcripts are kept.", folderPath: nil)
        }
    }

    /// Calls whose audio the cleanup would move to the Trash.
    func cleanupTargets(days: Int) -> [StorageCleanup.Candidate] {
        StorageCleanup.select(Storage.candidates(base: AppSettings.baseFolder), olderThanDays: days, now: Date())
            .filter { !busyFolders.contains($0.id) && currentFolder?.key != $0.id }
    }

    /// Moves the audio of the given calls to the Trash. Returns calls and bytes cleaned.
    @discardableResult
    func cleanUpAudio(_ targets: [StorageCleanup.Candidate]) -> (Int, Int64) {
        var count = 0
        var bytes: Int64 = 0
        for t in targets {
            let folder = RecordingFolder(url: URL(fileURLWithPath: t.id, isDirectory: true))
            // Checked again: a call may have started transcribing since the list was made.
            guard !isBusy(folder) else { continue }
            do {
                try trashAudio(folder)
                count += 1
                bytes += t.audioBytes
            } catch {
                Log.app.error("Cleanup failed for \(t.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return (count, bytes)
    }

    // MARK: Call detection

    /// A call started. `rule` is never `.never` here: those are filtered out by the monitor.
    /// Returns true when the recording started with the fallback title, so the monitor
    /// can look for a better one in the call window.
    @discardableResult
    func meetingStarted(_ call: DetectedCall, rule: SourceRule) -> Bool {
        guard !isRecording else { return false }
        var usedFallback = false
        let chosen = AppSettings.sourceRules.autoRecords(call.source)
        if AppSettings.autoRecordMode.records(rule: rule, chosen: chosen) {
            let event = CalendarService.shared.currentEvent()
            let date = Date()
            let title = CallTitle.choose(eventTitle: event?.title, windowTitle: call.windowTitle, source: call.source, date: date)
            usedFallback = title == CallTitle.fallback(source: call.source, date: date)
            let fallbackTitle = usedFallback ? title : nil
            Task {
                await startRecording(title: title, language: AppSettings.language, event: event, call: call,
                                     autoStarted: true, fallbackTitle: fallbackTitle)
            }
            if rule == .new {
                Notifier.shared.postNewSource(call)
            } else {
                Notifier.shared.post(.recordingStarted, title: "Recording started", body: "Call detected in \(call.source).", folderPath: nil)
            }
        } else {
            Notifier.shared.postCallDetected(call, isNew: rule == .new)
        }
        return usedFallback
    }

    /// Gives the auto-started recording the call window's title, unless it was renamed meanwhile.
    func retitleAutoStarted(to newTitle: String) {
        guard case .recording(let current, let start) = phase, let folder = currentFolder,
              let fallback = autoFallbackTitle, current == fallback,
              folder.loadMeta()?.title == fallback else { return }
        autoFallbackTitle = nil
        folder.updateMeta { $0.title = newTitle }
        phase = .recording(title: newTitle, start: start)
        libraryVersion += 1
        Log.app.info("Recording titled from the call window")
    }

    /// Saves the Always/Never choice for a source. Never also discards the recording
    /// that was started automatically for it.
    func setRule(_ rule: SourceRule, for source: String) {
        var rules = AppSettings.sourceRules
        rules.set(rule, for: source)
        AppSettings.sourceRules = rules
        if rule == .never, let current = autoStartedSource, current.caseInsensitiveCompare(source) == .orderedSame {
            discardRecording()
        }
    }

    func meetingEnded(app: String, behavior: CallEndBehavior) {
        guard isRecording, behavior.notifies else { return }
        Notifier.shared.postCallEnded(app: app, asks: behavior == .ask,
                                      autoStopSeconds: behavior.autoStopSeconds(delay: AppSettings.detectAutoStopSeconds))
    }

    func meetingAutoStop() {
        guard isRecording else { return }
        stopRecording()
        Notifier.shared.post(.recordingStopped, title: "Recording stopped", body: "The call seems to have ended.", folderPath: nil)
    }

    // MARK: Tags

    /// Every tag used so far, most recent first.
    func knownTags() -> [String] {
        Tags.byRecency(RecordingFolder.scan(base: AppSettings.baseFolder).compactMap { f in
            f.loadMeta().map { ($0.date, $0.tags ?? []) }
        })
    }

    /// Tags used for the last recording, offered as a one-click suggestion.
    var lastTags: [String] { AppSettings.defaults.stringArray(forKey: Keys.lastTags) ?? [] }

    func setTags(_ folder: RecordingFolder, _ tags: [String]) {
        folder.setTags(tags)
        libraryVersion += 1
    }

    /// Relabels one recording; detection rules are not touched.
    func setSource(_ folder: RecordingFolder, _ source: String) {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.updateMeta { $0.source = s.isEmpty ? nil : s }
        libraryVersion += 1
    }

    func addTag(_ tag: String, to folders: [RecordingFolder]) {
        for f in folders { setTags(f, (f.loadMeta()?.tags ?? []) + [tag]) }
    }

    // MARK: Library actions

    func rename(_ folder: RecordingFolder, to newTitle: String) {
        do {
            guard try folder.rename(to: newTitle) else { return }
        } catch {
            Log.app.error("Renaming a call failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        libraryVersion += 1
    }

    func trashCall(_ folder: RecordingFolder) throws {
        try FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
        if let last = AppSettings.lastRecordingFolder, RecordingFolder(url: last).key == folder.key {
            AppSettings.lastRecordingFolder = nil
        }
        libraryVersion += 1
    }

    func trashAudio(_ folder: RecordingFolder) throws {
        for url in folder.allAudioURLs {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        folder.removePartials()
        folder.updateMeta { $0.audioDeleted = true }
        libraryVersion += 1
    }

    /// Sends the webhook for a recording; failures become a notification.
    func sendWebhook(_ folder: RecordingFolder) async {
        do {
            let result = try await Webhook.send(folder: folder)
            Log.app.info("Webhook sent, HTTP \(result.statusCode)")
        } catch {
            lastErrorDetail = error.localizedDescription
            Notifier.shared.post(.problem, title: "Webhook failed", body: error.localizedDescription, folderPath: folder.url.path)
        }
    }

    /// Fires the webhook with the last recording (or sample data) and describes the outcome.
    func testWebhook() async -> String {
        let payload: Webhook.Payload
        var source = "sample data"
        if let folder = lastFolder, let p = try? Webhook.Payload.from(folder: folder) {
            payload = p
            source = "last recording \"\(p.title)\""
        } else {
            payload = .sample
        }
        do {
            let r = try await Webhook.send(payload: payload)
            return "HTTP \(r.statusCode) (sent \(source))\n\(r.bodyPrefix)"
        } catch {
            return "\(error.localizedDescription) (sent \(source))"
        }
    }

    /// Stores display names for raw speaker labels and regenerates transcript.md.
    func renameSpeakers(_ folder: RecordingFolder, names: [String: String]) throws {
        try folder.renameSpeakers(names)
        libraryVersion += 1
    }

    // MARK: Agents

    /// Reloads the library after kaiku-mcp changed calls on disk.
    func reloadLibrary() {
        libraryVersion += 1
    }

    /// Commands from other tools, e.g. the Raycast extension. They never change a saved call.
    private func handleControl(_ request: ControlRequest) {
        switch request {
        case .startRecording(let title):
            guard !isRecording else { return }
            Task { await startRecording(title: title ?? "", language: AppSettings.language) }
        case .stopRecording:
            stopRecording()
        case .togglePause:
            togglePause()
        case .addBookmark:
            addBookmark()
        case .toggleMute:
            MicMuter.shared.toggle()
        case .openCall(let path):
            guard let folder = CallLibrary(base: AppSettings.baseFolder).folder(atPath: path) else {
                Log.app.error("Ignored a request to open a folder outside the recordings folder: \(path, privacy: .public)")
                return
            }
            openInLibrary(folder)
            showInLibrary(folder, at: nil)
        case .chat(let question, let tag, let source, let days):
            let from = days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
            let filter = CallFilter(tag: tag, source: source, from: from)
            let calls = CallLibrary(base: AppSettings.baseFolder).calls()
                .filter { filter.matches($0.meta) && $0.folder.hasTranscript }
                .map { ChatCall(ref: ChatPrompt.ref(forFolderName: $0.folder.url.lastPathComponent), path: $0.folder.key,
                                title: $0.meta.title, date: $0.meta.date, duration: $0.meta.durationSeconds) }
            chat.start(with: calls)
            chat.draft = question
            chat.send()
            chatRequested = true
            openInLibrary(nil)
        }
    }

    /// Work an agent asked for through kaiku-mcp with a `kaiku://` URL. Only when the user
    /// allowed agents to edit calls, and only for calls in the recordings folder.
    func handleAgentURL(_ url: URL) {
        if let control = ControlRequest(url: url) {
            handleControl(control)
            return
        }
        guard let request = AgentRequest(url: url) else {
            Log.app.error("Ignored URL: \(url.absoluteString, privacy: .public)")
            return
        }
        guard AppSettings.agentsAllowEdits else {
            Log.app.error("Ignored an agent request: editing by agents is off")
            return
        }
        guard let folder = CallLibrary(base: AppSettings.baseFolder).folder(atPath: request.folder) else {
            Log.app.error("Ignored an agent request for a folder outside the recordings folder: \(request.folder, privacy: .public)")
            return
        }
        guard !isBusy(folder) else { return }
        switch request {
        case .transcribe:
            Log.app.info("An agent asked to transcribe \(folder.url.lastPathComponent, privacy: .public)")
            transcribe(folder: folder, provider: AppSettings.provider)
        case .summarize:
            Log.app.info("An agent asked to summarize \(folder.url.lastPathComponent, privacy: .public)")
            Task {
                do {
                    try await generateSummary(folder)
                } catch {
                    lastErrorDetail = error.localizedDescription
                    Notifier.shared.post(.problem, title: "Summary failed", body: error.localizedDescription, folderPath: folder.url.path)
                }
            }
        }
    }

    private func finishBusy(_ folder: RecordingFolder) {
        jobs[folder.key] = nil
        busyFolders.remove(folder.key)
        busyStage[folder.key] = nil
        libraryVersion += 1
        updateGlyphTimer()
    }

    func stage(for folder: RecordingFolder) -> String? { busyStage[folder.key] }

    func isRecordingFolder(_ folder: RecordingFolder) -> Bool { currentFolder?.key == folder.key }

    func isBusy(_ folder: RecordingFolder) -> Bool {
        busyFolders.contains(folder.key) || currentFolder?.key == folder.key
    }

    // MARK: Helpers

    func showErrorDetails() {
        guard let detail = lastErrorDetail else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Kaiku error details"
        alert.informativeText = detail
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(detail, forType: .string)
        }
    }

    func openBaseFolder() {
        let base = AppSettings.baseFolder
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        NSWorkspace.shared.open(base)
    }

    private func fail(_ message: String, folderPath: String?) {
        Log.app.error("\(message, privacy: .public)")
        lastErrorDetail = message
        if !isRecording {
            phase = .error(message)
            errorFolder = folderPath.map { RecordingFolder(url: URL(fileURLWithPath: $0)) }
        }
        Notifier.shared.post(.problem, title: "Kaiku error", body: message, folderPath: folderPath)
    }

    private func makeFolder(date: Date, title: String) throws -> RecordingFolder {
        let base = AppSettings.baseFolder
        let name = Naming.folderName(date: date, title: title)
        var url = base.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = base.appendingPathComponent("\(name)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RecordingFolder(url: url)
    }

    /// Tells once per recording when audio can't be written (e.g. the disk is full).
    private func checkWriteErrors(_ rec: CallRecorder) {
        guard !writeErrorShown, let error = rec.writeErrors.first else { return }
        writeErrorShown = true
        lastErrorDetail = "Audio is not being saved:\n\n\(rec.writeErrors.joined(separator: "\n"))"
        Notifier.shared.post(.problem, title: "Audio is not being saved",
                             body: "\(error)\nCheck the free space on the disk.", folderPath: currentFolder?.url.path)
    }

    private func startLevelTimer(_ rec: CallRecorder) {
        levels.hasMic = rec.hasMic
        levelTimer?.invalidate()
        // 12.5 Hz for the meters in the open panel, else once a second for the silence guard.
        let interval = panelVisible ? 0.08 : 1.0
        levelTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                let state = AppState.shared
                guard let rec = state.recorder else { return }
                let sys = rec.systemLevel
                let mic = rec.micLevel
                state.levels.mic = mic
                state.levels.system = max(sys, state.levels.system * 0.8)
                state.checkLeftRunning(micLevel: mic, systemLevel: sys)
                state.checkWriteErrors(rec)
                if sys > 0.002 && !AppSettings.defaults.bool(forKey: Keys.systemAudioVerified) {
                    AppSettings.defaults.set(true, forKey: Keys.systemAudioVerified)
                }
            }
        }
        // Lets macOS batch the wakeups with others.
        levelTimer?.tolerance = interval * 0.2
    }

    /// Stops the recording after a long silence or at the maximum length.
    private func checkLeftRunning(micLevel: Float, systemLevel: Float) {
        guard isRecording else { return }
        recordingGuard.silenceLimit = Double(AppSettings.stopAfterSilenceSeconds)
        recordingGuard.maxDuration = Double(AppSettings.maxRecordingSeconds)
        guard let reason = recordingGuard.update(recorded: elapsed(at: Date()), micLevel: micLevel, systemLevel: systemLevel) else { return }
        let body: String
        switch reason {
        case .silence:
            body = "No sound for \(RecordingGuard.describe(seconds: AppSettings.stopAfterSilenceSeconds))."
        case .maxDuration:
            body = "It reached the maximum length of \(RecordingGuard.describe(seconds: AppSettings.maxRecordingSeconds))."
        }
        Log.app.info("Recording stopped by itself: \(body, privacy: .public)")
        // The silence at the end is cut, so it is neither transcribed nor kept.
        stopRecording(keepUntil: reason == .silence ? recordingGuard.lastSound + RecordingGuard.tailAfterSound : nil)
        Notifier.shared.post(.recordingStopped, title: "Recording stopped", body: body, folderPath: nil)
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        levels.mic = 0
        levels.system = 0
    }

    private func updateGlyphTimer() {
        if busyFolders.isEmpty {
            glyphTimer?.invalidate()
            glyphTimer = nil
        } else if glyphTimer == nil {
            glyphTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                Task { @MainActor in AppState.shared.glyphFrame &+= 1 }
            }
        }
    }

    /// Snapshot rendering only: puts the state machine in a given visual state.
    func setPreview(phase: Phase, busy: [String: String] = [:], mic: Float = 0, system: Float = 0, error: String? = nil,
                    paused: Bool = false, bookmarks: [Bookmark] = []) {
        self.phase = phase
        self.isPaused = paused
        self.bookmarks = bookmarks
        self.clock = nil
        self.busyStage = busy
        self.busyFolders = Set(busy.keys)
        self.lastErrorDetail = error
        levels.mic = mic
        levels.system = system
        if case .recording(_, let start) = phase { tick.now = start.addingTimeInterval(754) }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AppState.shared.tick.now = Date() }
        }
        ticker?.tolerance = 0.1
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private static func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

/// A call to select in the library, and the time to play it from.
struct LibrarySeek: Equatable {
    let key: String
    let time: Double?
    /// Tells two requests for the same moment apart.
    let id = UUID()
}
