import Foundation

public enum Naming {
    /// Lowercase ASCII slug, max 60 chars.
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var out = ""
        var lastDash = false
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII {
                out.unicodeScalars.append(ch)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 60 {
            out = String(out.prefix(60))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "recording" : out
    }

    /// Folder name like "2026-09-23_1430_weekly-sync".
    public static func folderName(date: Date, title: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(df.string(from: date))_\(slug(title))"
    }

    /// Default title like "Call 2026-09-23 14:30".
    public static func defaultTitle(date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return "Call \(df.string(from: date))"
    }
}
