import AVFoundation

/// Turns the recorded audio of one track into 16-bit mono PCM at a fixed rate, the form
/// whisper and the streaming APIs take.
final class LivePCMConverter {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(sampleRate: Int) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true) else {
            throw LiveEngineError("no \(sampleRate) Hz audio format")
        }
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Int16] {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw LiveEngineError("could not convert \(buffer.format) to \(format)")
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let samples = out.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
    }
}
