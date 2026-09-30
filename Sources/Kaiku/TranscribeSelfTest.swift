import Foundation
import KaikuCore

extension SelfTest {
    /// `Kaiku --transcribe-selftest <audio file> [language] [--provider <name>] [--download]`:
    /// transcribes the file as one track with a provider and prints the segments. The
    /// language is "auto" or an ISO code; the provider is one of the `ProviderKind` names,
    /// Apple's when left out. A missing speech model is only downloaded with `--download`.
    static func runTranscribe(file: URL, language: String, provider name: String?, download: Bool) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        print("Kaiku transcription self-test")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        guard let kind = ProviderKind(rawValue: name ?? ProviderKind.apple.rawValue) else {
            print("FAIL: unknown provider \(name ?? ""). Providers: \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))")
            return 1
        }
        guard kind.isAvailable else {
            print("FAIL: \(kind.displayName) can't run on this version of macOS")
            return 1
        }
        print("Provider: \(kind.displayName), language: \(language)")
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        Task.detached {
            code = await transcribe(file: file, language: AppSettings.normalizedLanguage(language), kind: kind, download: download)
            sem.signal()
        }
        sem.wait()
        return code
    }

    private static func transcribe(file: URL, language: String, kind: ProviderKind, download: Bool) async -> Int32 {
        if kind == .apple, #available(macOS 26, *) {
            var readiness = await AppleSpeech.readiness(language: language)
            if case .needsDownload(let what) = readiness {
                guard download else {
                    print("NOT READY: \(what) Get it in Settings > Transcription, or run again with --download.")
                    return 2
                }
                print("Downloading: \(what)")
                do {
                    try await AppleSpeech.download(language: language) { print("  \(Int($0 * 100))%") }
                } catch {
                    print("FAIL: download: \(error.localizedDescription)")
                    return 1
                }
                readiness = await AppleSpeech.readiness(language: language)
            }
            guard readiness == .ready else {
                print("NOT READY: \(readiness)")
                return 2
            }
        }
        do {
            let provider = try ProviderFactory.make(kind)
            let seconds = AudioFiles.duration(file) ?? 0
            print("Transcribing \(file.lastPathComponent) (\(String(format: "%.1f", seconds)) s) with \(provider.name)")
            let started = Date()
            let result = try await provider.transcribe(fileURL: file, language: language == "auto" ? nil : language, diarize: false)
            let took = Date().timeIntervalSince(started)
            for s in result.segments {
                print("\(TranscriptFormatter.timestamp(s.start))-\(TranscriptFormatter.timestamp(s.end)) \(s.text)")
            }
            if let detected = result.detectedLanguage { print("Detected language: \(detected)") }
            print(String(format: "%d segment(s) in %.1f s", result.segments.count, took))
            let ordered = zip(result.segments, result.segments.dropFirst()).allSatisfy { $0.start <= $1.start }
            let inside = result.segments.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= seconds + 1 }
            if !ordered { print("FAIL: segments out of order") }
            if !inside { print("FAIL: segment times outside the file") }
            let ok = !result.segments.isEmpty && ordered && inside
            print(ok ? "PASS" : "FAIL")
            return ok ? 0 : 1
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
    }
}
