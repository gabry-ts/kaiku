import AVFoundation
import KaikuCore

extension SelfTest {
    /// `Kaiku --live-selftest <audio file> [language] [--download]`: feeds the file to the
    /// live engine as the microphone track and prints what it reports. The language is
    /// "auto" (the system language) or an ISO code. A missing speech model is only
    /// downloaded with `--download`.
    static func runLive(file: URL, language: String, download: Bool) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        print("Kaiku live transcription self-test")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        guard let kind = LiveEngineKind.available.first, let engine = kind.make() else {
            print("FAIL: no live engine can run on this version of macOS")
            return 1
        }
        print("Engine: \(kind.displayName), language: \(language)")
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        Task.detached {
            code = await live(file: file, language: language, download: download, kind: kind, engine: engine)
            sem.signal()
        }
        sem.wait()
        return code
    }

    private static func live(file: URL, language: String, download: Bool, kind: LiveEngineKind, engine: LiveEngine) async -> Int32 {
        var readiness = await kind.readiness(language: language)
        if case .needsDownload(let what) = readiness {
            guard download else {
                print("NOT READY: \(what) Run again with --download to get it.")
                return 2
            }
            print("Downloading: \(what)")
            do {
                try await kind.download(language: language) { print("  \(Int($0 * 100))%") }
            } catch {
                print("FAIL: download: \(error.localizedDescription)")
                return 1
            }
            readiness = await kind.readiness(language: language)
        }
        guard readiness == .ready else {
            print("NOT READY: \(readiness)")
            return 2
        }

        let printer = Task { () -> (LiveTranscript, String?) in
            var transcript = LiveTranscript()
            var failure: String?
            for await event in engine.events {
                switch event {
                case .partial(let track, let text):
                    print("  partial [\(track.label)] \(text)")
                    transcript.setPartial(text, speaker: track, at: 0)
                case .final(let track, let text, let start, let end):
                    print("FINAL   [\(track.label)] \(TranscriptFormatter.timestamp(start))-\(TranscriptFormatter.timestamp(end)) \(text)")
                    transcript.addFinal(text, speaker: track, start: start, end: end)
                case .failed(let message):
                    print("FAILED  \(message)")
                    failure = message
                }
            }
            return (transcript, failure)
        }
        do {
            try await engine.start(language: language)
            let input = try AVAudioFile(forReading: file)
            let format = input.processingFormat
            let frames = AVAudioFrameCount(format.sampleRate / 10)
            print("Feeding \(file.lastPathComponent): \(format)")
            var fed: AVAudioFramePosition = 0
            while input.framePosition < input.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
                try input.read(into: buffer, frameCount: frames)
                if buffer.frameLength == 0 { break }
                engine.feed(buffer, track: .me, at: Double(fed) / format.sampleRate)
                fed += AVAudioFramePosition(buffer.frameLength)
                // A little faster than real time, so partial results show as they would live.
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            print("FAIL: \(error.localizedDescription)")
            await engine.stop()
            return 1
        }
        await engine.stop()
        let (heard, failed) = await printer.value
        print("\(heard.finals.count) final line(s)")
        print(failed == nil && !heard.finals.isEmpty ? "PASS" : "FAIL")
        return failed == nil && !heard.finals.isEmpty ? 0 : 1
    }
}
