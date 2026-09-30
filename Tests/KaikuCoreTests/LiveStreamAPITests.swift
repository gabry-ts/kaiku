import XCTest
@testable import KaikuCore

final class LiveStreamAPITests: XCTestCase {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    func testOpenAISessionIsTranscriptionOnly() {
        let message = object(OpenAIRealtime.sessionUpdate(model: "gpt-4o-transcribe", language: "it"))
        XCTAssertEqual(message["type"] as? String, "session.update")
        let session = message["session"] as? [String: Any]
        XCTAssertEqual(session?["type"] as? String, "transcription")
        let input = (session?["audio"] as? [String: Any])?["input"] as? [String: Any]
        XCTAssertEqual((input?["format"] as? [String: Any])?["type"] as? String, "audio/pcm")
        XCTAssertEqual((input?["format"] as? [String: Any])?["rate"] as? Int, 24_000)
        XCTAssertEqual((input?["transcription"] as? [String: Any])?["model"] as? String, "gpt-4o-transcribe")
        XCTAssertEqual((input?["transcription"] as? [String: Any])?["language"] as? String, "it")
        XCTAssertEqual((input?["turn_detection"] as? [String: Any])?["type"] as? String, "server_vad")

        let auto = object(OpenAIRealtime.sessionUpdate(model: "whisper-1", language: nil))
        let transcription = (((auto["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any])?["transcription"] as? [String: Any]
        XCTAssertNil(transcription?["language"])
    }

    func testOpenAIAudioIsBase64() {
        let message = object(OpenAIRealtime.append(Data([1, 0, 255, 127])))
        XCTAssertEqual(message["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(message["audio"] as? String, "AQD/fw==")
        XCTAssertEqual(object(OpenAIRealtime.commit)["type"] as? String, "input_audio_buffer.commit")
    }

    func testOpenAIModelFallsBackToOneThatStreams() {
        XCTAssertEqual(OpenAIRealtime.model(saved: "gpt-4o-transcribe"), "gpt-4o-transcribe")
        XCTAssertEqual(OpenAIRealtime.model(saved: " GPT-4o-mini-transcribe "), "gpt-4o-mini-transcribe")
        XCTAssertEqual(OpenAIRealtime.model(saved: "whisper-1"), "whisper-1")
        XCTAssertEqual(OpenAIRealtime.model(saved: "gpt-4o-transcribe-diarize"), OpenAIRealtime.defaultModel)
        XCTAssertEqual(OpenAIRealtime.model(saved: ""), OpenAIRealtime.defaultModel)
    }

    func testOpenAIEvents() {
        XCTAssertEqual(OpenAIRealtime.parse(#"{"type":"input_audio_buffer.speech_started","item_id":"a","audio_start_ms":1200}"#),
                       .speechStarted(item: "a", ms: 1200))
        XCTAssertEqual(OpenAIRealtime.parse(#"{"type":"input_audio_buffer.speech_stopped","item_id":"a","audio_end_ms":3400}"#),
                       .speechStopped(item: "a", ms: 3400))
        XCTAssertEqual(OpenAIRealtime.parse(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#), .committed(item: "a"))
        XCTAssertEqual(OpenAIRealtime.parse(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","content_index":0,"delta":"Hello,"}"#),
                       .delta(item: "a", text: "Hello,"))
        XCTAssertEqual(OpenAIRealtime.parse(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","content_index":0,"transcript":"Hello, how are you?"}"#),
                       .final(item: "a", text: "Hello, how are you?"))
        XCTAssertEqual(OpenAIRealtime.parse(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"a","error":{"message":"x"}}"#),
                       .final(item: "a", text: ""))
        XCTAssertEqual(OpenAIRealtime.parse(#"{"type":"error","error":{"type":"invalid_request_error","message":"Bad model"}}"#), .error("Bad model"))
        XCTAssertEqual(OpenAIRealtime.parse(#"{"type":"error","error":{"code":"input_audio_buffer_commit_empty","message":"Empty"}}"#), .ignored)
        XCTAssertEqual(OpenAIRealtime.parse(#"{"type":"session.updated"}"#), .ignored)
        XCTAssertEqual(OpenAIRealtime.parse("not json"), .ignored)
    }
}
