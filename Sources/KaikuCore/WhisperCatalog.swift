import Foundation

/// The whisper.cpp ggml models offered for download.
public struct WhisperModel: Identifiable, Hashable {
    public let file: String
    public let name: String
    public let size: String
    public let note: String
    public var id: String { file }

    public init(file: String, name: String, size: String, note: String) {
        self.file = file
        self.name = name
        self.size = size
        self.note = note
    }

    public var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }

    public static let catalog: [WhisperModel] = [
        WhisperModel(file: "ggml-tiny.bin", name: "Tiny", size: "75 MB", note: "Fastest, rough quality"),
        WhisperModel(file: "ggml-base.bin", name: "Base", size: "142 MB", note: "Fast, basic quality"),
        WhisperModel(file: "ggml-small.bin", name: "Small", size: "466 MB", note: "Good balance"),
        WhisperModel(file: "ggml-medium.bin", name: "Medium", size: "1.5 GB", note: "Accurate, slower"),
        WhisperModel(file: "ggml-large-v3-turbo-q5_0.bin", name: "Large v3 Turbo (compact)", size: "547 MB", note: "Great quality, fast"),
        WhisperModel(file: "ggml-large-v3-turbo.bin", name: "Large v3 Turbo", size: "1.6 GB", note: "Best quality"),
    ]

    public static let recommended = catalog[4]
}
