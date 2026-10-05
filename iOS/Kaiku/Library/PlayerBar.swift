import AVFoundation
import KaikuCore
import Observation
import SwiftUI

/// Plays the audio of one call.
@MainActor
@Observable
final class PlayerModel {
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false
    let duration: Double

    init?(folder: RecordingFolder) {
        let url = FileManager.default.fileExists(atPath: folder.mixedURL.path) ? folder.mixedURL : folder.audioURLs.first
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        self.player = player
        duration = player.duration
        player.prepareToPlay()
    }

    var currentTime: Double { player?.currentTime ?? 0 }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            isPlaying = player.play()
        }
    }

    func seek(to seconds: Double, play: Bool = false) {
        player?.currentTime = min(max(0, seconds), duration)
        if play, player?.isPlaying == false { toggle() }
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    func stop() {
        player?.stop()
        isPlaying = false
    }
}

struct PlayerBar: View {
    let player: PlayerModel
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let position = scrub ?? player.currentTime
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { position }, set: { scrub = $0 }), in: 0...max(player.duration, 1)) { editing in
                        if !editing, let value = scrub {
                            player.seek(to: value)
                            scrub = nil
                        }
                    }
                    HStack {
                        Text(duration(position))
                        Spacer()
                        Text("-" + duration(max(0, player.duration - position)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 36) {
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                }
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
            }
            .font(.title2)
            .buttonStyle(.plain)
        }
        .padding()
        .background(.bar)
    }
}
