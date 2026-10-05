import Foundation

public struct AudioCaptureError: LocalizedError {
    public let message: String
    public init(_ message: String, _ status: OSStatus? = nil) {
        self.message = status.map { "\(message) (OSStatus \($0)\(fourCC(Int($0))))" } ?? message
    }
    /// Wraps an underlying error, keeping its domain and code.
    public init(_ message: String, underlying: Error) {
        self.message = "\(message): \(underlying.diagnosticDescription)"
    }
    public var errorDescription: String? { message }
}

extension Error {
    /// "message [domain code 'fourcc']" for diagnostics.
    public var diagnosticDescription: String {
        if let e = self as? AudioCaptureError { return e.message }
        let ns = self as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)\(fourCC(ns.code))]"
    }
}

/// Renders an OSStatus as a four-char code when printable, e.g. " '!dat'".
public func fourCC(_ code: Int) -> String {
    let v = UInt32(truncatingIfNeeded: code)
    let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "" }
    return " '" + String(decoding: bytes, as: UTF8.self) + "'"
}

public struct ImportError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}
