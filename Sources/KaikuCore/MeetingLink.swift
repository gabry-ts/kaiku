import Foundation

/// A Google Meet, Microsoft Teams, Webex or FaceTime join link the meeting bot can open.
public struct MeetingLink: Equatable, Sendable {
    public enum Platform: String, Sendable {
        case meet, teams, webex, faceTime

        public var name: String {
            switch self {
            case .meet: return "Google Meet"
            case .teams: return "Microsoft Teams"
            case .webex: return "Webex"
            case .faceTime: return "FaceTime"
            }
        }
    }

    public let platform: Platform
    public let url: URL

    /// The link in `text`, or nil when it isn't a join link the bot knows.
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
        (.webex, try! NSRegularExpression(pattern: #"(?:https?://)?[a-z0-9.-]+\.webex\.com/(?:[a-z0-9-]+/)?(?:meet/|join/|j\.php|wbxmjs/)[^\s<>"']+"#,
                                          options: .caseInsensitive)),
        // FaceTime links open in Chrome; calls to a phone number or Apple ID don't.
        (.faceTime, try! NSRegularExpression(pattern: #"(?:https?://)?facetime\.apple\.com/join[^\s<>"']+"#,
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
