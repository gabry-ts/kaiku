import Foundation

/// How much of a call has sound in it, across its tracks: what "speech" means for the
/// short recording check. Any sound above the silence level counts, not only voices.
public enum SpeechTime {
    /// Seconds covered by the ranges of every track together, overlaps counted once.
    public static func total(_ tracks: [[TimeRange]]) -> Double {
        let ranges = tracks.flatMap { $0 }.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var total = 0.0
        var current: TimeRange?
        for range in ranges {
            if var open = current, range.start <= open.end {
                open.end = max(open.end, range.end)
                current = open
            } else {
                total += current?.duration ?? 0
                current = range
            }
        }
        return total + (current?.duration ?? 0)
    }

    /// The stretches of one track with sound, from its per-window peak levels.
    public static func soundRanges(peaks: [Float], window: Double, duration: Double,
                                   options: SilenceTrimmer.Options) -> [TimeRange] {
        let silences = SilenceTrimmer.silences(peaks: peaks, window: window, options: options)
        return SilenceTrimmer.keepRanges(duration: duration, silences: silences, padding: 0)
    }

    /// Seconds with sound in the audio files of a call. Blocking; call off the main thread.
    public static func measure(_ urls: [URL], options: SilenceTrimmer.Options) -> Double {
        total(urls.compactMap { url in
            guard let (peaks, duration) = try? AudioFiles.peaks(url, window: 0.05) else { return nil }
            return soundRanges(peaks: peaks, window: 0.05, duration: duration, options: options)
        })
    }
}
