import AppKit
import AVFoundation
import KaikuCore

/// Dictation from any app: the shortcut records, the provider transcribes, the optional
/// polish step cleans the text up, and the text is pasted where the cursor is.
///
/// While a call is being recorded dictation still works: it reads the call's microphone
/// with its own capture session, which leaves the call recording as it is.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case polishing
        /// The end of a dictation, shown for a moment.
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var modeName: String?
    @Published private(set) var history: [DictationEntry] = []

    /// Longest dictation; it stops by itself then.
    static let maxSeconds: TimeInterval = 300

    private var trigger = DictationTrigger(style: .hold)
    private var recorder: DictationRecorder?
    private var work: Task<Void, Never>?
    private var meter: Timer?
    private var limit: Timer?
    private var hide: Task<Void, Never>?

    private init() {
        modeName = DictationConfig.activeMode?.name
        history = DictationConfig.history.load()
    }

    var providerName: String { DictationConfig.provider.displayName }

    var isBusy: Bool { phase == .transcribing || phase == .polishing }

    /// Registers the shortcuts and warms whisper up to match the settings. Does nothing
    /// that asks for a permission.
    func apply() {
        HotKeyManager.apply()
        DictationWhisper.shared.apply()
        modeName = DictationConfig.activeMode?.name
        if !DictationConfig.enabled { cancel() }
    }

    // MARK: Shortcut

    func shortcutPressed() {
        guard DictationConfig.enabled, !isBusy else { return }
        if !trigger.isActive { trigger.style = DictationConfig.activation }
        handle(trigger.press())
    }

    func shortcutReleased() {
        handle(trigger.release())
    }

    private func handle(_ action: DictationTrigger.Action) {
        switch action {
        case .start: start()
        case .stop: finish()
        case .cancel: cancel()
        case .none: break
        }
    }

    /// Next mode, from the second shortcut or the HUD.
    func cycleMode() {
        guard DictationConfig.enabled,
              let next = DictationModes.next(after: DictationConfig.activeMode?.id, in: DictationConfig.modes) else { return }
        DictationConfig.setActiveMode(next.id)
        modeName = next.name
        if phase == .idle || isFinished { show(.done("Mode: \(next.name)"), for: 1.2) }
    }

    func modesChanged() { modeName = DictationConfig.activeMode?.name }

    /// Esc, or a dictation too short to keep: drops the audio and any work on it.
    func cancel() {
        trigger.reset()
        stopMeters()
        _ = recorder?.stop()
        recorder = nil
        work?.cancel()
        work = nil
        HotKeyManager.releaseEscape()
        if phase != .idle { finishHUD(after: 0) }
    }

    // MARK: Recording

    private func start() {
        if let problem = startProblem() {
            trigger.reset()
            show(.failed(problem), for: 3)
            return
        }
        let device = (AppState.shared.isRecording ? AppState.shared.currentMic : nil)
            ?? AudioDevices.resolveMicrophone(setting: AppSettings.microphone)
            ?? AudioDevices.resolveMicrophone(setting: AudioDevices.automatic)
        guard let device else {
            trigger.reset()
            show(.failed("No microphone found."), for: 3)
            return
        }
        let recorder = DictationRecorder()
        do {
            try recorder.start(device: device)
        } catch {
            trigger.reset()
            show(.failed(error.localizedDescription), for: 4)
            return
        }
        self.recorder = recorder
        hide?.cancel()
        modeName = DictationConfig.activeMode?.name
        phase = .recording
        level = 0
        DictationHUD.shared.show()
        HotKeyManager.claimEscape()
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let c = DictationController.shared
                c.level = c.recorder?.level ?? 0
            }
        }
        limit = Timer.scheduledTimer(withTimeInterval: Self.maxSeconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                let c = DictationController.shared
                if c.phase == .recording {
                    c.trigger.reset()
                    c.finish()
                }
            }
        }
    }

    /// Why a dictation can't start, nil when it can. Asks for the microphone the first time.
    private func startProblem() -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in Permissions.shared.refresh() } }
            return "Allow the microphone, then dictate again."
        default:
            return "Microphone access is off. Allow Kaiku in System Settings > Privacy & Security > Microphone."
        }
        if MicMuter.shared.isMuted { return "Microphones are muted in Kaiku." }
        return nil
    }

    private func stopMeters() {
        meter?.invalidate()
        meter = nil
        limit?.invalidate()
        limit = nil
        level = 0
    }

    private func finish() {
        stopMeters()
        guard let recorder else { return }
        let samples = recorder.stop()
        self.recorder = nil
        guard !ChunkAudio.isSilent(samples, sampleRate: DictationRecorder.sampleRate) else {
            HotKeyManager.releaseEscape()
            show(.failed("No speech heard."), for: 1.5)
            return
        }
        phase = .transcribing
        let kind = DictationConfig.provider
        let language = DictationConfig.language
        let mode = DictationConfig.activeMode
        work = Task {
            do {
                var text = try await DictationTranscriber.transcribe(samples, provider: kind, language: language)
                try Task.checkCancellation()
                guard !text.isEmpty else { throw ProviderError(message: "No speech recognized.") }
                var note: String?
                if DictationConfig.polish {
                    phase = .polishing
                    do {
                        text = try await polish(text, mode: mode)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.transcription.error("Dictation polish failed: \(error.localizedDescription, privacy: .public)")
                        text = DictationText.removeFillers(text)
                        note = "Polish failed, inserted as heard"
                    }
                } else {
                    text = DictationText.removeFillers(text)
                }
                try Task.checkCancellation()
                deliver(text, mode: mode, note: note)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Log.transcription.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
                HotKeyManager.releaseEscape()
                show(.failed(error.localizedDescription), for: 4)
            }
            work = nil
        }
    }

    private func polish(_ text: String, mode: DictationMode?) async throws -> String {
        let kind = mode?.provider.flatMap(SummaryProviderKind.init(rawValue:)) ?? DictationConfig.polishProvider
        let override = (mode?.model ?? "").trimmingCharacters(in: .whitespaces)
        let model = override.isEmpty ? DictationConfig.polishModel(for: kind) : override
        let prompt = DictationPrompt.render(template: DictationConfig.polishPrompt, text: text, mode: mode)
        let answer = try await SummaryJob.complete(kind: kind, model: model, prompt: prompt, maxTokens: 2048, timeout: 60)
        let cleaned = DictationPrompt.cleanResponse(answer)
        return cleaned.isEmpty ? text : cleaned
    }

    private func deliver(_ text: String, mode: DictationMode?, note: String?) {
        HotKeyManager.releaseEscape()
        guard !text.isEmpty else {
            show(.failed("No speech recognized."), for: 2)
            return
        }
        let outcome = TextInserter.insert(text)
        remember(text, mode: mode)
        switch outcome {
        case .pasted:
            show(.done(note ?? "Inserted"), for: note == nil ? 0.8 : 2.5)
        case .copied:
            show(.done("Copied. Press ⌘V to paste."), for: 3)
            Notifier.shared.post(.problem, title: "Dictation copied to the clipboard",
                                 body: "Allow Kaiku in Accessibility to paste dictations where the cursor is.", folderPath: nil)
        }
    }

    // MARK: History

    private func remember(_ text: String, mode: DictationMode?) {
        do {
            history = try DictationConfig.history.append(DictationEntry(text: text, mode: mode?.name))
        } catch {
            Log.app.error("Could not save dictation history: \(error.localizedDescription, privacy: .public)")
        }
    }

    func copy(_ entry: DictationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    func remove(_ entry: DictationEntry) {
        history = (try? DictationConfig.history.remove(id: entry.id)) ?? history
    }

    func clearHistory() {
        try? DictationConfig.history.clear()
        history = []
    }

    // MARK: HUD

    private var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }

    private func show(_ phase: Phase, for seconds: TimeInterval) {
        self.phase = phase
        DictationHUD.shared.show()
        finishHUD(after: seconds)
    }

    private func finishHUD(after seconds: TimeInterval) {
        hide?.cancel()
        hide = Task {
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            phase = .idle
            DictationHUD.shared.hide()
        }
    }
}
