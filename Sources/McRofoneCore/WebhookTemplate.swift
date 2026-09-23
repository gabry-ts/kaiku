import Foundation

/// Renders custom webhook bodies with `{{placeholder}}` substitution.
public enum WebhookTemplate {
    public enum Value {
        /// Text value; JSON-escaped when the body is JSON.
        case string(String)
        /// Already-serialized value (JSON array, number) inserted verbatim.
        case raw(String)
    }

    public static let placeholders = [
        "title", "date", "duration_seconds", "language", "provider",
        "folder_path", "transcript_path", "transcript_markdown", "segments_json", "audio_paths_json",
        "bookmarks_json", "summary_markdown", "estimated_cost_usd", "tags", "tags_json",
    ]

    /// Replaces every `{{name}}` found in `values`. Unknown placeholders are left untouched.
    public static func render(_ template: String, values: [String: Value], jsonEscape: Bool) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                out += rest[open.lowerBound...]
                return out
            }
            let name = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = values[name] {
                switch value {
                case .string(let s): out += jsonEscape ? escapeJSONString(s) : s
                case .raw(let r): out += r
                }
            } else {
                out += rest[open.lowerBound..<close.upperBound]
            }
            rest = afterOpen[close.upperBound...]
        }
        out += rest
        return out
    }

    /// Escapes a string for use inside JSON double quotes (quotes not included).
    public static func escapeJSONString(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(s), let quoted = String(data: data, encoding: .utf8), quoted.count >= 2 else {
            return s
        }
        return String(quoted.dropFirst().dropLast())
    }
}
