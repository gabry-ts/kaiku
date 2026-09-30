import AVFoundation
import KaikuCore
import os

/// What differs between the streaming speech-to-text APIs: where to connect and how
/// their messages are written. The pure parts live in `KaikuCore`.
struct LiveStreamAPI: Sendable {
    /// Who the audio goes to, e.g. "OpenAI".
    let name: String
    /// 16-bit mono PCM at this rate is what `audio` is given.
    let sampleRate: Int
    /// The socket to open for a language ("auto" or an ISO code).
    let request: @Sendable (_ key: String, _ language: String) -> URLRequest
    /// Sent once the socket is open, before any audio.
    let opening: @Sendable (_ language: String) -> [String]
    let audio: @Sendable (Data) -> String
    /// Sent when the recording stops, to get the text of the last words.
    let closing: [String]
    let parse: @Sendable (String) -> LiveStreamMessage
}

/// Live transcription with a cloud API over WebSocket. Each track has its own socket,
/// opened when its first audio arrives; the audio is streamed as it is recorded and the
/// API sends the text back while it is spoken.
final class StreamingLiveEngine: LiveEngine, @unchecked Sendable {
    let events: AsyncStream<LiveEvent>
    private let report: AsyncStream<LiveEvent>.Continuation

    private struct Chunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let time: Double
    }

    private struct State {
        var workers: [Task<Void, Never>] = []
        var stopped = false
    }

    private let api: LiveStreamAPI
    private let key: String?
    /// Shown when `key` is missing.
    private let keyHint: String
    private let audio: [LiveTrack: AsyncStream<Chunk>]
    private let feeders: [LiveTrack: AsyncStream<Chunk>.Continuation]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(api: LiveStreamAPI, key: String?, keyHint: String) {
        self.api = api
        self.key = key
        self.keyHint = keyHint
        (events, report) = AsyncStream<LiveEvent>.makeStream()
        var audio: [LiveTrack: AsyncStream<Chunk>] = [:]
        var feeders: [LiveTrack: AsyncStream<Chunk>.Continuation] = [:]
        for track in LiveTrack.allCases {
            // About half a minute of audio can wait for the socket; older audio is dropped.
            let (stream, continuation) = AsyncStream<Chunk>.makeStream(bufferingPolicy: .bufferingNewest(4000))
            audio[track] = stream
            feeders[track] = continuation
        }
        self.audio = audio
        self.feeders = feeders
    }

    deinit {
        feeders.values.forEach { $0.finish() }
        report.finish()
    }

    func start(language: String) async throws {
        guard let key else { throw LiveEngineError(keyHint) }
        Log.transcription.info("Live transcription with \(self.api.name, privacy: .public)")
        state.withLock { s in
            guard !s.stopped else { return }
            s.workers = LiveTrack.allCases.map { track in Task { await self.run(track, key: key, language: language) } }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer, track: LiveTrack, at time: Double) {
        feeders[track]?.yield(Chunk(buffer: buffer, time: time))
    }

    func stop() async {
        feeders.values.forEach { $0.finish() }
        let workers = state.withLock { s -> [Task<Void, Never>] in
            s.stopped = true
            defer { s.workers = [] }
            return s.workers
        }
        for worker in workers { await worker.value }
        report.finish()
    }

    /// One track from its first buffer to the end of the recording.
    private func run(_ track: LiveTrack, key: String, language: String) async {
        guard let audio = audio[track] else { return }
        var link: Link?
        var failures = 0
        var queued = Data()
        // The audio goes out a tenth of a second at a time.
        let enough = api.sampleRate * 2 / 10
        do {
            let converter = try LivePCMConverter(sampleRate: api.sampleRate)
            for await chunk in audio {
                if let broken = link, let why = broken.failure {
                    broken.close()
                    link = nil
                    // One new try after a failure; a socket that gave text earns another.
                    if broken.gotText { failures = 0 }
                    failures += 1
                    guard failures <= 1 else {
                        fail(track, why)
                        return
                    }
                    Log.transcription.error("Live socket to \(self.api.name, privacy: .public) failed, reconnecting: \(why, privacy: .public)")
                }
                let samples = try converter.convert(chunk.buffer)
                guard !samples.isEmpty else { continue }
                if link == nil {
                    queued.removeAll(keepingCapacity: true)
                    let new = Link(api: api, request: api.request(key, language), track: track, report: report)
                    await new.open(api.opening(language))
                    link = new
                }
                link?.note(recorded: chunk.time, duration: Double(samples.count) / Double(api.sampleRate))
                samples.withUnsafeBufferPointer { queued.append(Data(buffer: $0)) }
                if queued.count >= enough {
                    await link?.send(api.audio(queued))
                    queued.removeAll(keepingCapacity: true)
                }
            }
            guard let link else { return }
            if !queued.isEmpty { await link.send(api.audio(queued)) }
            await link.finish(api.closing)
            if let why = link.failure { fail(track, why) }
        } catch {
            link?.close()
            fail(track, error.localizedDescription)
        }
    }

    /// Reports the failure and stops taking audio, which ends both tracks.
    private func fail(_ track: LiveTrack, _ message: String) {
        let source = track == .me ? "microphone" : "call audio"
        report.yield(.failed("Live transcription stopped (\(source)): \(message)"))
        feeders.values.forEach { $0.finish() }
    }

    /// One socket, with what is known about the utterances in flight on it.
    private final class Link: @unchecked Sendable {
        private struct State {
            /// From the socket's audio clock, which starts when it opens, to recording time.
            var timeline = LiveTimeline()
            /// Recording time at the end of the audio sent.
            var sentUntil: Double = 0
            /// Utterances whose final text hasn't come yet, oldest first.
            var open: [String] = []
            var texts: [String: String] = [:]
            var starts: [String: Double] = [:]
            var ends: [String: Double] = [:]
            /// Start of the current utterance when the API doesn't name it.
            var lineStart: Double?
            var failure: String?
            var gotText = false
            var closing = false
        }

        private let api: LiveStreamAPI
        private let task: URLSessionWebSocketTask
        private let track: LiveTrack
        private let report: AsyncStream<LiveEvent>.Continuation
        private let state = OSAllocatedUnfairLock(initialState: State())
        private var receiver: Task<Void, Never>?

        init(api: LiveStreamAPI, request: URLRequest, track: LiveTrack, report: AsyncStream<LiveEvent>.Continuation) {
            self.api = api
            self.track = track
            self.report = report
            task = URLSession.shared.webSocketTask(with: request)
        }

        /// Why the socket can't be used any more, nil while it works.
        var failure: String? { state.withLock { $0.failure } }
        /// True once the socket has given a finished line.
        var gotText: Bool { state.withLock { $0.gotText } }

        func open(_ messages: [String]) async {
            task.resume()
            receiver = Task { await self.receive() }
            for message in messages { await send(message) }
        }

        func note(recorded: Double, duration: Double) {
            state.withLock { s in
                s.timeline.note(recorded: recorded, duration: duration)
                s.sentUntil = recorded + duration
            }
        }

        func send(_ message: String) async {
            guard failure == nil else { return }
            do { try await task.send(.string(message)) } catch { broke(error) }
        }

        /// Waits a few seconds at most for the text of what was said last, then closes.
        func finish(_ closing: [String]) async {
            for message in closing { await send(message) }
            let began = Date()
            while !Task.isCancelled, Date().timeIntervalSince(began) < 3 {
                let (waiting, failed) = state.withLock { (!$0.open.isEmpty || $0.lineStart != nil, $0.failure != nil) }
                if failed || (!waiting && Date().timeIntervalSince(began) >= 0.8) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            close()
        }

        func close() {
            state.withLock { $0.closing = true }
            task.cancel(with: .normalClosure, reason: nil)
            receiver?.cancel()
        }

        private func receive() async {
            do {
                while true {
                    switch try await task.receive() {
                    case .string(let text): handle(api.parse(text))
                    case .data(let data): handle(api.parse(String(decoding: data, as: UTF8.self)))
                    @unknown default: break
                    }
                }
            } catch {
                broke(error)
            }
        }

        private func broke(_ error: Error) {
            let why = describe(error)
            state.withLock { s in
                if !s.closing, s.failure == nil { s.failure = why }
            }
        }

        private func describe(_ error: Error) -> String {
            // A refused handshake says more than the socket error does.
            if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
                switch status {
                case 401, 403: return "\(api.name) rejected the API key."
                case 429: return "\(api.name) rate limit or quota reached."
                default: return "HTTP \(status) from \(api.name)"
                }
            }
            if let reason = task.closeReason.flatMap({ String(data: $0, encoding: .utf8) }), !reason.isEmpty { return reason }
            return error.localizedDescription
        }

        private func handle(_ message: LiveStreamMessage) {
            let track = self.track
            let events = state.withLock { s -> [LiveEvent] in
                var events: [LiveEvent] = []
                func inFlight() -> String {
                    s.open.compactMap { s.texts[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
                }
                switch message {
                case .speechStarted(let item, let ms):
                    s.starts[item] = s.timeline.recordedTime(ms / 1000)
                    if !s.open.contains(item) { s.open.append(item) }
                case .speechStopped(let item, let ms):
                    s.ends[item] = s.timeline.recordedTime(ms / 1000)
                case .committed(let item):
                    if !s.open.contains(item) { s.open.append(item) }
                case .delta(let item, let text):
                    if !s.open.contains(item) { s.open.append(item) }
                    s.texts[item, default: ""] += text
                    events.append(.partial(track, inFlight()))
                case .partial(let text):
                    if s.lineStart == nil { s.lineStart = s.sentUntil }
                    events.append(.partial(track, text))
                case .final(let item, let text):
                    let start = item.flatMap { s.starts[$0] } ?? s.lineStart ?? s.sentUntil
                    let end = item.flatMap { s.ends[$0] } ?? s.sentUntil
                    if let item {
                        s.open.removeAll { $0 == item }
                        s.texts[item] = nil
                        s.starts[item] = nil
                        s.ends[item] = nil
                    }
                    s.lineStart = nil
                    if !text.isEmpty { s.gotText = true }
                    events.append(.final(track, text, start: start, end: max(start, end)))
                    // The final line took the place of the partial one: show what is left.
                    let rest = inFlight()
                    if !rest.isEmpty { events.append(.partial(track, rest)) }
                case .error(let why):
                    if !s.closing, s.failure == nil { s.failure = why }
                case .ignored:
                    break
                }
                return events
            }
            events.forEach { report.yield($0) }
            if case .error = message { task.cancel(with: .goingAway, reason: nil) }
        }
    }
}

extension LiveStreamAPI {
    /// OpenAI Realtime transcription, with the model chosen for OpenAI file transcription.
    static var openAI: LiveStreamAPI {
        let model = OpenAIRealtime.model(saved: AppSettings.model(for: .openAI))
        return LiveStreamAPI(
            name: "OpenAI", sampleRate: OpenAIRealtime.sampleRate,
            request: { key, _ in
                var request = URLRequest(url: OpenAIRealtime.url, timeoutInterval: 20)
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                return request
            },
            opening: { [OpenAIRealtime.sessionUpdate(model: model, language: $0 == "auto" ? nil : $0)] },
            audio: { OpenAIRealtime.append($0) },
            closing: [OpenAIRealtime.commit],
            parse: { OpenAIRealtime.parse($0) })
    }
}
