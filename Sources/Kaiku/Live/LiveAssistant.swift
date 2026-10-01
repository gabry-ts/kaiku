import Foundation
import KaikuCore

/// The Summary and Ask tabs of the live window: a bullet summary brought up to date as
/// the call goes on, and questions answered from what was said so far. Uses the summary
/// provider and key; never runs unless switched on in Settings.
@MainActor
final class LiveAssistant: ObservableObject {
    /// True for a recording started with the feature on.
    @Published private(set) var isEnabled = false
    @Published private(set) var bullets: [String] = []
    @Published private(set) var summaryUpdated: Date?
    @Published private(set) var isSummarizing = false
    @Published private(set) var summaryError: String?
    @Published private(set) var exchanges: [LiveAssist.Exchange] = []
    @Published private(set) var askError: String?

    /// How often the summary checks for new lines, in seconds.
    private static let tick: Double = 15

    private var transcript: () -> LiveTranscript = { LiveTranscript() }
    /// Final lines already in the summary.
    private var summarized: Set<Int> = []
    private var lastRun = Date()
    private var ticker: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    private var nextID = 0

    var isAsking: Bool { askTask != nil }

    /// The summary as Markdown, nil while it's empty.
    var summaryMarkdown: String? { bullets.isEmpty ? nil : LiveAssist.markdown(bullets) }

    /// The provider in use when it can't run yet, for the empty state.
    var missingKeyProvider: SummaryProviderKind? {
        let kind = AppSettings.summaryProvider
        return kind.problem == nil ? nil : kind
    }

    /// Starts with a recording when the feature is on.
    /// - Parameter transcript: what has been heard so far.
    func start(transcript: @escaping () -> LiveTranscript) {
        reset()
        guard AppSettings.liveAssistEnabled else { return }
        isEnabled = true
        self.transcript = transcript
        lastRun = Date()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tick * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.summarize(force: false)
            }
        }
    }

    func reset() {
        ticker?.cancel()
        summaryTask?.cancel()
        askTask?.cancel()
        ticker = nil
        summaryTask = nil
        askTask = nil
        isEnabled = false
        bullets = []
        summaryUpdated = nil
        isSummarizing = false
        summaryError = nil
        exchanges = []
        askError = nil
        summarized = []
        transcript = { LiveTranscript() }
    }

    /// Adds the lines not in the summary yet; unless forced, only once enough was said.
    func summarize(force: Bool = true) {
        guard isEnabled, summaryTask == nil else { return }
        let lines = LiveAssist.pending(transcript(), summarized: summarized)
        guard !lines.isEmpty else { return }
        guard force || LiveAssist.shouldSummarize(pendingWords: LiveAssist.wordCount(lines),
                                                  sinceLast: Date().timeIntervalSince(lastRun)) else { return }
        let kind = AppSettings.summaryProvider
        if let problem = kind.problem {
            summaryError = "\(problem) Check Settings > Transcription > Summary."
            return
        }
        let model = AppSettings.liveSummaryModel(for: kind)
        let prompt = LiveAssist.summaryPrompt(bullets: bullets, newLines: LiveAssist.text(lines))
        let ids = lines.map(\.id)
        lastRun = Date()
        isSummarizing = true
        summaryTask = Task { [weak self] in
            let reply: Result<String, Error>
            do {
                reply = .success(try await SummaryJob.complete(kind: kind, model: model, prompt: prompt,
                                                               maxTokens: 1024, timeout: kind.cli == nil ? 60 : 120))
            } catch {
                reply = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.summaryTask = nil
            self.isSummarizing = false
            switch reply {
            case .success(let text):
                let parsed = LiveAssist.parseBullets(text)
                guard !parsed.isEmpty else {
                    self.summaryError = "The summary came back empty. Trying again shortly."
                    return
                }
                self.bullets = parsed
                self.summarized.formUnion(ids)
                self.summaryUpdated = Date()
                self.summaryError = nil
            case .failure(let error):
                self.summaryError = error.localizedDescription
            }
        }
    }

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, askTask == nil, !question.isEmpty else { return }
        let kind = AppSettings.summaryProvider
        if let problem = kind.problem {
            askError = "\(problem) Check Settings > Transcription > Summary."
            return
        }
        let model = AppSettings.liveAskModel(for: kind)
        let prompt = LiveAssist.askPrompt(transcript: LiveAssist.transcript(transcript().lines),
                                          history: exchanges, question: question)
        nextID += 1
        let id = nextID
        exchanges.append(LiveAssist.Exchange(id: id, question: question))
        askError = nil
        askTask = Task { [weak self] in
            let reply: Result<String, Error>
            do {
                reply = .success(try await SummaryJob.complete(kind: kind, model: model, prompt: prompt,
                                                               maxTokens: 400, timeout: kind.cli == nil ? 30 : 90))
            } catch {
                reply = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.askTask = nil
            switch reply {
            case .success(let answer):
                if let i = self.exchanges.firstIndex(where: { $0.id == id }) { self.exchanges[i].answer = answer }
            case .failure(let error):
                self.exchanges.removeAll { $0.id == id }
                self.askError = error.localizedDescription
            }
        }
    }

    /// Snapshot rendering only.
    func setPreview(bullets: [String], exchanges: [LiveAssist.Exchange], updated: Date? = Date()) {
        reset()
        isEnabled = true
        self.bullets = bullets
        self.exchanges = exchanges
        summaryUpdated = updated
        nextID = exchanges.map(\.id).max() ?? 0
    }
}
