import Foundation
import os

/// Unified logging. View with:
/// log show --last 1h --info --predicate 'subsystem == "com.gabrielepartiti.kaiku"'
enum Log {
    static let audio = Logger(subsystem: "com.gabrielepartiti.kaiku", category: "audio")
    static let transcription = Logger(subsystem: "com.gabrielepartiti.kaiku", category: "transcription")
    static let app = Logger(subsystem: "com.gabrielepartiti.kaiku", category: "app")
}
