import Foundation
import os

/// Unified logging. View with:
/// log show --last 1h --info --predicate 'subsystem == "com.gabrielepartiti.kaiku"'
enum Log {
    static let audio = Logger(subsystem: "com.gabrielepartiti.kaiku", category: "audio")
    static let transcription = Logger(subsystem: "com.gabrielepartiti.kaiku", category: "transcription")
    static let app = Logger(subsystem: "com.gabrielepartiti.kaiku", category: "app")
}

extension Error {
    /// "message [domain code 'fourcc']" for diagnostics.
    var diagnosticDescription: String {
        if let e = self as? AudioCaptureError { return e.message }
        let ns = self as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)\(fourCC(ns.code))]"
    }
}

/// Renders an OSStatus as a four-char code when printable, e.g. " '!dat'".
func fourCC(_ code: Int) -> String {
    let v = UInt32(truncatingIfNeeded: code)
    let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "" }
    return " '" + String(decoding: bytes, as: UTF8.self) + "'"
}
