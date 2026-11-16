import AVFoundation
import SwiftUI

@MainActor
final class AudioPlayback: ObservableObject {
    @Published var playing = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func load(_ url: URL?) {
        stop()
        guard let url else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            duration = player?.duration ?? 0
            player?.prepareToPlay()
        } catch { self.error = "Couldn't open audio: \(error.localizedDescription)" }
    }
    func toggle() {
        guard let player else { return }
        if playing { player.pause(); playing = false; ticker?.cancel(); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            if player.currentTime >= player.duration { player.currentTime = 0 }
            guard player.play() else { throw CaptionError.message("Audio playback couldn't start.") }
            playing = true
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let player = self.player else { return }
                    self.position = player.currentTime
                    if !player.isPlaying { self.playing = false; return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func seek(_ seconds: Double) { player?.currentTime = seconds; position = seconds }
    func stop() {
        ticker?.cancel(); ticker = nil
        player?.stop(); player = nil; playing = false; position = 0
        if AVAudioSession.sharedInstance().category == .playback { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
