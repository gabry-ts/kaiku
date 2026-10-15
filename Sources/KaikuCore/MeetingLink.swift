import Foundation

/// A Google Meet or Microsoft Teams join link the meeting bot can open.
public struct MeetingLink: Equatable, Sendable {
    public enum Platform: String, Sendable {
        case meet, teams

        public var name: String {
            switch self {
            case .meet: return "Google Meet"
            case .teams: return "Microsoft Teams"
            }
        }
    }

    public let platform: Platform
    public let url: URL

    /// The link in `text`, or nil when it isn't a Meet or Teams join link.
    public init?(_ text: String) {
        guard let found = Self.find(in: text) else { return nil }
        self = found
    }

    private init(platform: Platform, url: URL) {
        self.platform = platform
        self.url = url
    }

    private static let patterns: [(Platform, NSRegularExpression)] = [
        (.meet, try! NSRegularExpression(pattern: #"(?:https?://)?meet\.google\.com/[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}(?:\?[^\s<>"']*)?"#,
                                         options: .caseInsensitive)),
        (.teams, try! NSRegularExpression(pattern: #"(?:https?://)?teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"']+"#,
                                          options: .caseInsensitive)),
    ]

    /// The first join link in free text: an event's URL, location or notes.
    public static func find(in text: String) -> MeetingLink? {
        var best: (range: NSRange, link: MeetingLink)?
        let whole = NSRange(text.startIndex..., in: text)
        for (platform, regex) in patterns {
            guard let match = regex.firstMatch(in: text, range: whole),
                  let range = Range(match.range, in: text) else { continue }
            var raw = String(text[range])
            // Trailing punctuation from the sentence around the link.
            while let last = raw.last, ".,;)>]".contains(last) { raw.removeLast() }
            if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
            guard let url = URL(string: raw) else { continue }
            if best == nil || match.range.location < best!.range.location {
                best = (match.range, MeetingLink(platform: platform, url: url))
            }
        }
        return best?.link
    }
}
