import Foundation

/// What a streaming speech-to-text API says on its socket, in the terms the live engines
/// share. Utterances are told apart by `item` where the API names them.
public enum LiveStreamMessage: Equatable, Sendable {
    /// Speech began `ms` into the audio sent on this connection.
    case speechStarted(item: String, ms: Double)
    /// Speech ended `ms` into the audio sent on this connection.
    case speechStopped(item: String, ms: Double)
    /// The audio of an utterance is complete and its text is on the way.
    case committed(item: String)
    /// More text of an utterance, to add to what came before.
    case delta(item: String, text: String)
    /// The whole text of the current utterance so far; it can still change.
    case partial(String)
    /// The finished text of an utterance. Empty when the API couldn't transcribe it.
    case final(item: String?, text: String)
    /// The API gave up on this connection.
    case error(String)
    /// Anything the engines don't need.
    case ignored
}

/// OpenAI Realtime API, transcription sessions: the messages sent and received.
public enum OpenAIRealtime {
    public static let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    /// The only rate a transcription session takes: 16-bit mono PCM at 24 kHz.
    public static let sampleRate = 24_000
    public static let defaultModel = "gpt-4o-mini-transcribe"

    /// The model for a live session given the one chosen for file transcription. Only
    /// the models that work with server voice detection are kept; the diarizing one and
    /// unknown names fall back to the default.
    public static func model(saved: String) -> String {
        let name = saved.trimmingCharacters(in: .whitespaces).lowercased()
        if name == "whisper-1" { return name }
        if name.hasPrefix("gpt-4o"), name.contains("transcribe"), !name.contains("diarize") { return name }
        return defaultModel
    }

    /// The first message: a transcription-only session where the server splits the audio
    /// into utterances at the pauses.
    /// - Parameter language: ISO 639-1 code, or nil to let the model detect it.
    public static func sessionUpdate(model: String, language: String?) -> String {
        var transcription: [String: Any] = ["model": model]
        if let language { transcription["language"] = language }
        let message: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": sampleRate],
                    "transcription": transcription,
                    "turn_detection": ["type": "server_vad"],
                ]],
            ],
        ]
        return json(message)
    }

    /// - Parameter pcm: 16-bit little-endian mono samples at `sampleRate`.
    public static func append(_ pcm: Data) -> String {
        #"{"type":"input_audio_buffer.append","audio":"\#(pcm.base64EncodedString())"}"#
    }

    /// Ends the utterance being spoken when the recording stops.
    public static let commit = #"{"type":"input_audio_buffer.commit"}"#

    public static func parse(_ text: String) -> LiveStreamMessage {
        guard let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = event["type"] as? String else { return .ignored }
        let item = event["item_id"] as? String
        switch type {
        case "input_audio_buffer.speech_started":
            guard let item, let ms = event["audio_start_ms"] as? Double else { return .ignored }
            return .speechStarted(item: item, ms: ms)
        case "input_audio_buffer.speech_stopped":
            guard let item, let ms = event["audio_end_ms"] as? Double else { return .ignored }
            return .speechStopped(item: item, ms: ms)
        case "input_audio_buffer.committed":
            return item.map { .committed(item: $0) } ?? .ignored
        case "conversation.item.input_audio_transcription.delta":
            guard let item, let delta = event["delta"] as? String else { return .ignored }
            return .delta(item: item, text: delta)
        case "conversation.item.input_audio_transcription.completed":
            return .final(item: item, text: event["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.failed":
            return .final(item: item, text: "")
        case "error":
            let error = event["error"] as? [String: Any]
            // Committing at the end of the recording when nothing was left to commit.
            if error?["code"] as? String == "input_audio_buffer_commit_empty" { return .ignored }
            return .error(error?["message"] as? String ?? "unknown error")
        default:
            return .ignored
        }
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
