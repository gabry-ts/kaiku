import AVFoundation
import CoreMedia

/// Writes the audio sample buffers of one broadcast track to CAF files, without resampling (the extension has 50 MB).
/// A change of audio format starts a new file: system.caf, system-2.caf, ...
final class BroadcastWriter {
    private let folder: URL
    private let name: String
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var buffer: AVAudioPCMBuffer?
    private var part = 0

    init(folder: URL, name: String) {
        self.folder = folder
        self.name = name
    }

    func append(_ sample: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              let incoming = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0 else { return }

        if file == nil || format != incoming {
            part += 1
            let url = folder.appendingPathComponent(part == 1 ? "\(name).caf" : "\(name)-\(part).caf")
            file = try? AVAudioFile(forWriting: url, settings: incoming.settings,
                                    commonFormat: incoming.commonFormat, interleaved: incoming.isInterleaved)
            format = incoming
        }
        if buffer == nil || buffer?.format != incoming || (buffer?.frameCapacity ?? 0) < frames {
            buffer = AVAudioPCMBuffer(pcmFormat: incoming, frameCapacity: frames)
        }
        guard let file, let buffer else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        try? file.write(from: buffer)
    }

    func close() {
        file = nil
        buffer = nil
    }
}
