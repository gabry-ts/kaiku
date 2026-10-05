import BackgroundTasks
import Foundation
import KaikuCore
import Observation
import UIKit

/// Transcribes calls one at a time. While it works, a continued processing task keeps the app running in the background.
@MainActor
@Observable
final class PhoneJobs {
    static let shared = PhoneJobs()

    /// Matches BGTaskSchedulerPermittedIdentifiers in Info.plist.
    nonisolated static let taskPattern = "com.gabrielepartiti.kaiku.ios.transcribe.*"
    nonisolated static let interruptedMessage = "Transcription interrupted when the app quit. Transcribe again."

    /// The call being transcribed, and what is being done to it.
    private(set) var current: RecordingFolder?
    private(set) var progress = ""
    private(set) var queue: [RecordingFolder] = []

    /// Called whenever a call changed on disk.
    var onChange: (() -> Void)?

    private var worker: Task<Void, Never>?
    private var currentJob: Task<Void, Never>?
    private var backgroundTask: BGContinuedProcessingTask?
    private var backgroundRequested = false
    private var batchTotal = 0
    private var batchDone = 0
    private var jobFraction = 0.0

    func isActive(_ folder: RecordingFolder) -> Bool {
        current?.key == folder.key || queue.contains { $0.key == folder.key }
    }

    /// The text shown for a call that is being transcribed or waits for its turn; nil otherwise.
    func status(for folder: RecordingFolder) -> String? {
        if current?.key == folder.key { return progress.isEmpty ? "Transcribing" : progress }
        return queue.contains { $0.key == folder.key } ? "Waiting to transcribe" : nil
    }

    func enqueue(_ folder: RecordingFolder) {
        guard !isActive(folder) else { return }
        folder.updateMeta {
            $0.status = .transcribing
            $0.error = nil
        }
        queue.append(folder)
        batchTotal += 1
        requestBackgroundTime()
        onChange?()
        if worker == nil { worker = Task { await drain() } }
    }

    /// Stops the call's transcription, or takes it off the queue.
    func cancel(_ folder: RecordingFolder) {
        if current?.key == folder.key {
            currentJob?.cancel()
        } else if let index = queue.firstIndex(where: { $0.key == folder.key }) {
            queue.remove(at: index)
            batchTotal -= 1
            folder.updateMeta {
                $0.status = .error
                $0.error = TranscriptionRun.cancelledMessage
            }
            onChange?()
        }
    }

    // MARK: Work

    private func drain() async {
        while !queue.isEmpty {
            let folder = queue.removeFirst()
            current = folder
            progress = "Preparing…"
            jobFraction = 0
            let job = Task { await process(folder) }
            currentJob = job
            await job.value
            currentJob = nil
            current = nil
            batchDone += 1
            onChange?()
        }
        batchTotal = 0
        batchDone = 0
        worker = nil
        finishBackgroundTask(success: true)
    }

    private func process(_ folder: RecordingFolder) async {
        let choice = PhoneSettings.transcriber
        let ticker = Task { [weak self] in
            // Keeps the system's progress display moving during long steps.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.advance(0.01)
            }
        }
        defer { ticker.cancel() }
        do {
            try await TranscriptionRun.run(folder: folder, config: choice.config(), makeProvider: { try choice.makeProvider() }) { [weak self] text in
                self?.progress = text
                self?.advance(0.25)
            }
        } catch is CancellationError {
            folder.updateMeta {
                $0.status = .error
                $0.error = TranscriptionRun.cancelledMessage
            }
        } catch {
            // The run has saved the error in meta.json.
        }
    }

    private func advance(_ amount: Double) {
        jobFraction = min(0.95, jobFraction + amount)
        guard let task = backgroundTask, batchTotal > 0 else { return }
        task.progress.completedUnitCount = Int64((Double(batchDone) + jobFraction) / Double(batchTotal) * 1000)
        task.updateTitle("Transcribing", subtitle: progress)
    }

    // MARK: Background

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskPattern, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in PhoneJobs.shared.attach(task) }
        }
    }

    /// Asks the system to keep the app running while it transcribes. Only works when the app is in the foreground.
    private func requestBackgroundTime() {
        guard backgroundTask == nil, !backgroundRequested, UIApplication.shared.applicationState == .active else { return }
        let identifier = String(Self.taskPattern.dropLast()) + UUID().uuidString
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Transcribing", subtitle: "Preparing…")
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            backgroundRequested = true
        } catch {
            // Transcription still runs while the app is open.
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        guard worker != nil else {
            task.setTaskCompleted(success: true)
            backgroundRequested = false
            return
        }
        backgroundTask = task
        task.progress.totalUnitCount = 1000
        task.expirationHandler = { Task { @MainActor in PhoneJobs.shared.expire() } }
        advance(0)
    }

    /// The system ended the background time: stop and leave the calls to be transcribed again.
    private func expire() {
        for folder in queue {
            folder.updateMeta {
                $0.status = .error
                $0.error = Self.interruptedMessage
            }
        }
        queue.removeAll()
        currentJob?.cancel()
        if let folder = current {
            folder.updateMeta {
                $0.status = .error
                $0.error = Self.interruptedMessage
            }
        }
        finishBackgroundTask(success: false)
    }

    private func finishBackgroundTask(success: Bool) {
        backgroundRequested = false
        guard let task = backgroundTask else { return }
        backgroundTask = nil
        task.setTaskCompleted(success: success)
    }

    // MARK: Launch

    /// Marks the calls a quit or a crash left in the middle of a transcription, so they can be transcribed again.
    /// Blocking: call off the main thread, before any transcription starts.
    nonisolated static func markInterrupted(base: URL) {
        for folder in RecordingFolder.scan(base: base) {
            guard var meta = folder.loadMeta(), meta.status == .transcribing else { continue }
            meta.status = .error
            meta.error = interruptedMessage
            try? folder.saveMeta(meta)
        }
    }
}
