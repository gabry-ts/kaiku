import os

/// Unified logging, same subsystem as the app so both show up in one log stream.
enum Log {
    static let transcription = Logger(subsystem: "com.gabrielepartiti.kaiku", category: "transcription")
    static let app = Logger(subsystem: "com.gabrielepartiti.kaiku", category: "app")
}
