import AVFoundation

@MainActor
final class PlayerModel: ObservableObject {
    @Published var player: AVPlayer? = nil
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isMuted = false

    private var timeObserverToken: Any?

    func load(url: URL) {
        if let token = timeObserverToken, let old = player {
            old.removeTimeObserver(token)
            timeObserverToken = nil
        }
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        currentTime = 0
        isPlaying = false
        isMuted = false

        let interval = CMTime(seconds: 0.15, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in self?.currentTime = time.seconds }
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func toggleMute() {
        guard let player else { return }
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// Uses a small tolerance so rapid scrubbing (dragging on the timeline) stays responsive
    /// instead of forcing an exact frame-accurate seek on every pixel of movement.
    func seek(to seconds: Double) {
        guard let player else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.12, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTime = seconds
    }
}
