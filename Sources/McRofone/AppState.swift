import AppKit
import AVFoundation
import McRofoneCore

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
    @Published private(set) var now = Date()
    /// Bumped whenever recordings on disk change, so the library can reload.
    @Published private(set) var libraryVersion = 0
    /// Folders currently being transcribed.
    @Published private(set) var busyFolders: Set<String> = []
    /// Full text of the last error or warning, for "Show Error Details".
    @Published private(set) var lastErrorDetail: String?
    /// Human readable step per busy folder key, e.g. "Transcribing call audio (2 of 2)…".
    @Published private(set) var busyStage: [String: String] = [:]
    /// Animation frame for the menu bar glyph while transcribing.
    @Published private(set) var glyphFrame = 0
    /// Recording to select when the library opens.
    @Published var librarySelection: String?
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

    final class Levels: ObservableObject {
        @Published var mic: Float = 0
        @Published var system: Float = 0
        @Published var hasMic = true
    }

    private var levelTimer: Timer?
    private var glyphTimer: Timer?

    private var recorder: CallRecorder?
    private var currentFolder: RecordingFolder?
    private var ticker: Timer?
    private var clock: RecordingClock?
    private var routes: [OutputRoute] = []
    private var muteIntervals: [MuteInterval] = []
    private var cleanupTimer: Timer?

    var isRecording: Bool { if case .recording = phase { return true } else { return false } }

    /// Recorded time of the current call (pauses excluded).
    var elapsed: TimeInterval {
        guard case .recording(_, let start) = phase else { return 0 }
        return (clock ?? RecordingClock(start: start)).recordedTime(at: now)
    }

    var lastFolder: RecordingFolder? {
        guard let url = AppSettings.lastRecordingFolder,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return RecordingFolder(url: url)
    }

    // MARK: Recording

    /// Shows the title prompt, prefilled from the calendar event happening now if any,
    /// otherwise from the app that started the call.
    func requestStart(app: String? = nil) {
        guard !isRecording else { return }
        let event = CalendarService.shared.currentEvent()
        let date = Date()
        let title = event?.title ?? app.map { "\($0) call \(Naming.defaultTitle(date: date).dropFirst(5))" } ?? Naming.defaultTitle(date: date)
        WindowManager.shared.showTitlePrompt(title: title, event: event)
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

    func startRecording(title rawTitle: String, language rawLanguage: String, event: CalendarEventInfo? = nil,
                        tags rawTags: [String] = []) async {
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

        do {
            let folder = try makeFolder(date: date, title: title)
            try folder.saveMeta(RecordingMeta(
                title: title, date: date, durationSeconds: 0, language: language,
                status: .recording, calendarEvent: event, tags: Tags.normalize(rawTags).nilIfEmpty))
            if !rawTags.isEmpty { AppSettings.defaults.set(Tags.normalize(rawTags), forKey: Keys.lastTags) }
            let micSetting = AppSettings.microphone
            let micDevice = AudioDevices.resolveMicrophone(setting: micSetting)
            if micDevice == nil && micSetting != AudioDevices.none {
                Log.audio.error("No usable non-Bluetooth microphone found; recording system audio only")
            }
            let rec = CallRecorder()
            routes = []
            rec.onRoute = { route, initial in
                DispatchQueue.main.async { AppState.shared.outputChanged(route, initial: initial) }
            }
            rec.onMicFallback = { lost, now in
                DispatchQueue.main.async { AppState.shared.micLost(lost, now: now) }
            }
            try rec.start(micURL: folder.micRawURL, systemURL: folder.systemRawURL, micDevice: micDevice)
            recorder = rec
            currentFolder = folder
            clock = RecordingClock(start: date)
            muteIntervals = MicMuter.shared.isMuted ? [MuteInterval(start: 0)] : []
            if !muteIntervals.isEmpty { folder.updateMeta { $0.muteIntervals = AppState.shared.muteIntervals } }
            currentMic = rec.micDevice
            isPaused = false
            bookmarks = []
            currentEvent = event
            AppSettings.lastRecordingFolder = folder.url
            phase = .recording(title: title, start: date)
            now = date
            startTicker()
            startLevelTimer(rec)
            libraryVersion += 1
            Log.app.info("Recording started: \(folder.url.path, privacy: .public)")
            if !rec.warnings.isEmpty {
                let detail = rec.warnings.joined(separator: "\n")
                lastErrorDetail = "Recording started with problems:\n\n\(detail)"
                Notifier.shared.post(title: "Recording one track only", body: detail, folderPath: nil)
            }
        } catch {
            fail("Could not start recording. \(error.diagnosticDescription)", folderPath: nil)
        }
    }

    func stopRecording() {
        guard case .recording(let title, _) = phase, let rec = recorder, let folder = currentFolder else { return }
        recorder = nil
        stopTicker()
        stopLevelTimer()
        let stopDate = Date()
        closeClock(at: stopDate)
        let duration = elapsed(at: stopDate)
        phase = .transcribing(title: title)
        busyFolders.insert(folder.key)
        busyStage[folder.key] = "Saving audio…"
        updateGlyphTimer()
        Task {
            let result = await Task.detached { () -> Result<Double?, Error> in
                rec.stop()
                return Result { try AudioFinalizer.finalize(folder) }
            }.value
            currentFolder = nil
            clock = nil
            currentMic = nil
            isPaused = false
            currentEvent = nil
            finishBusy(folder)
            phase = .idle
            switch result {
            case .success:
                folder.updateMeta { $0.durationSeconds = duration }
                transcribe(folder: folder, provider: AppSettings.provider)
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
        stopTicker()
        stopLevelTimer()
        let date = Date()
        closeClock(at: date)
        let duration = elapsed(at: date)
        phase = .idle
        folder.updateMeta { $0.durationSeconds = duration }
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
            Notifier.shared.post(title: "Audio output changed", body: "Still recording, now from \(route.name).", folderPath: nil, force: true)
        }
    }

    private func micLost(_ lost: String, now: AudioDevice?) {
        guard isRecording else { return }
        currentMic = now
        if let now {
            Notifier.shared.post(title: "Microphone disconnected", body: "Switched to \(now.name). Still recording.", folderPath: nil, force: true)
        } else {
            levels.hasMic = false
            lastErrorDetail = "\(lost) was disconnected and no other microphone is available. Only the call audio is being recorded."
            Notifier.shared.post(title: "Microphone disconnected", body: "No other microphone found. Recording the call audio only.", folderPath: nil, force: true)
        }
    }

    /// Mic picker in the panel. Uses the same hot-swap as the automatic fallback.
    func switchMicrophone(to device: AudioDevice) {
        guard let rec = recorder else { return }
        Task {
            let result = await Task.detached { Result { try rec.switchMicrophone(to: device) } }.value
            switch result {
            case .success: currentMic = device
            case .failure(let error):
                fail("Couldn't switch to \(device.name): \(error.diagnosticDescription)", folderPath: nil)
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
        now = date
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

    func retryLast() {
        guard let folder = lastFolder else { return }
        transcribe(folder: folder, provider: AppSettings.provider)
    }

    func transcribe(folder: RecordingFolder, provider: ProviderKind) {
        guard !busyFolders.contains(folder.key) else { return }
        let title = folder.loadMeta()?.title ?? folder.url.lastPathComponent
        busyFolders.insert(folder.key)
        busyStage[folder.key] = "Starting…"
        if !isRecording { phase = .transcribing(title: title) }
        libraryVersion += 1
        updateGlyphTimer()

        Task {
            do {
                try await TranscriptionJob.run(folder: folder, providerKind: provider) { [weak self] stage in
                    self?.busyStage[folder.key] = stage
                }
                recoveredFolders.removeAll { $0.key == folder.key }
                if AppSettings.summaryEnabled {
                    busyStage[folder.key] = "Writing summary…"
                    do { try await SummaryJob.run(folder: folder) } catch {
                        lastErrorDetail = error.localizedDescription
                        Notifier.shared.post(title: "Summary failed", body: error.localizedDescription, folderPath: folder.url.path)
                    }
                }
                finishBusy(folder)
                if !isRecording { phase = .done(title: title) }
                Notifier.shared.postTranscriptReady(title: title, folderPath: folder.url.path)
                if AppSettings.webhookEnabled { await sendWebhook(folder) }
            } catch {
                finishBusy(folder)
                fail("Transcription failed for \"\(title)\": \(error.diagnosticDescription)", folderPath: folder.url.path)
            }
        }
    }

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
        Task {
            let outcomes = await Task.detached { Recovery.recoverAll(base: base, skip: skip) }.value
            guard !outcomes.isEmpty else { return }
            libraryVersion += 1
            for o in outcomes where o.recovered {
                recoveredFolders.append(o.folder)
                Notifier.shared.postRecovered(title: o.title, folderPath: o.folder.url.path)
            }
        }
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
            Notifier.shared.post(title: "Old audio moved to the Trash",
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

    func meetingStarted(app: String) {
        guard !isRecording else { return }
        if AppSettings.detectAutoStart {
            let event = CalendarService.shared.currentEvent()
            let title = event?.title ?? "\(app) call \(Naming.defaultTitle(date: Date()).dropFirst(5))"
            Task { await startRecording(title: title, language: AppSettings.language, event: event) }
            Notifier.shared.post(title: "Recording started", body: "Call detected in \(app).", folderPath: nil)
        } else {
            Notifier.shared.postCallDetected(app: app)
        }
    }

    func meetingEnded(app: String) {
        guard isRecording, AppSettings.detectEndNotify else { return }
        Notifier.shared.postCallEnded(app: app, autoStopSeconds: AppSettings.detectAutoStopSeconds)
    }

    func meetingAutoStop() {
        guard isRecording else { return }
        stopRecording()
        Notifier.shared.post(title: "Recording stopped", body: "The call seems to have ended.", folderPath: nil)
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
        guard var meta = folder.loadMeta() else { return }
        meta.tags = Tags.normalize(tags).nilIfEmpty
        try? folder.saveMeta(meta)
        if let raw = folder.loadSegments() { _ = try? TranscriptWriter.write(folder: folder, meta: meta, rawSegments: raw) }
        libraryVersion += 1
    }

    func addTag(_ tag: String, to folders: [RecordingFolder]) {
        for f in folders { setTags(f, (f.loadMeta()?.tags ?? []) + [tag]) }
    }

    // MARK: Library actions

    func rename(_ folder: RecordingFolder, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        folder.updateMeta { $0.title = title }
        if var text = try? String(contentsOf: folder.transcriptURL, encoding: .utf8), text.hasPrefix("# ") {
            let firstLineEnd = text.firstIndex(of: "\n") ?? text.endIndex
            text.replaceSubrange(text.startIndex..<firstLineEnd, with: "# \(title)")
            try? text.write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
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
            Notifier.shared.post(title: "Webhook failed", body: error.localizedDescription, folderPath: folder.url.path)
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
        guard var meta = folder.loadMeta(), let raw = folder.loadSegments() else {
            throw ProviderError(message: "This recording has no segments.json; re-transcribe it first.")
        }
        let clean = names.compactMapValues { v -> String? in
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }.filter { $0.key != $0.value }
        meta.speakerNames = clean.isEmpty ? nil : clean
        try folder.saveMeta(meta)
        try TranscriptWriter.write(folder: folder, meta: meta, rawSegments: raw)
        libraryVersion += 1
    }

    private func finishBusy(_ folder: RecordingFolder) {
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
        alert.messageText = "mc.Rofone error details"
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
        if !isRecording { phase = .error(message) }
        Notifier.shared.post(title: "mc.Rofone error", body: message, folderPath: folderPath)
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

    private func startLevelTimer(_ rec: CallRecorder) {
        levels.hasMic = rec.hasMic
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            Task { @MainActor in
                let state = AppState.shared
                guard let rec = state.recorder else { return }
                let sys = rec.systemLevel
                state.levels.mic = rec.micLevel
                state.levels.system = max(sys, state.levels.system * 0.8)
                if sys > 0.002 && !AppSettings.defaults.bool(forKey: Keys.systemAudioVerified) {
                    AppSettings.defaults.set(true, forKey: Keys.systemAudioVerified)
                }
            }
        }
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
        if case .recording(_, let start) = phase { now = start.addingTimeInterval(754) }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AppState.shared.now = Date() }
        }
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
