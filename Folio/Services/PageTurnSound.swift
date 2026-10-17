import AVFAudio

@MainActor
protocol PageTurnSoundPlaying: AnyObject {
    func play(volume: Double)
    func stop()
}

protocol PageTurnAudioHandling: Sendable {
    func play(volume: Double) async
    func stop() async
}

/// A short optional effect. Reading continues if the asset or audio route is unavailable.
@MainActor
final class PageTurnSound: PageTurnSoundPlaying {
    static var resourceURL: URL? { Bundle.main.url(forResource: "book-turn-page-sound", withExtension: "mp3") }
    private let engine: any PageTurnAudioHandling
    private var operation: Task<Void, Never>?
    private var interruption: NSObjectProtocol?

    init(engine: (any PageTurnAudioHandling)? = nil) {
        self.engine = engine ?? PageTurnAudioEngine(url: Self.resourceURL)
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        operation?.cancel()
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        let engine = engine
        let previous = operation
        Task { await previous?.value; await engine.stop() }
    }

    func play(volume: Double) {
        guard volume > 0, volume.isFinite else { stop(); return }
        let previous = operation
        previous?.cancel()
        let engine = engine
        operation = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await engine.play(volume: volume)
        }
    }

    func stop() {
        let previous = operation
        previous?.cancel()
        let engine = engine
        // Serialize cleanup with activation; canceled activation must never
        // resume playback after the reader has closed or entered the background.
        operation = Task { await previous?.value; await engine.stop() }
    }
}

/// All player and session work runs on this actor's executor, away from UIKit.
private actor PageTurnAudioEngine: PageTurnAudioHandling {
    private let url: URL?
    private var player: AVAudioPlayer?
    private var configured = false
    private var active = false

    init(url: URL?) { self.url = url }

    func play(volume: Double) async {
        guard let url, !Task.isCancelled else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            if !configured {
                try session.setCategory(.ambient, mode: .default)
                configured = true
            }
            if !active {
                if #available(iOS 27.0, *) {
                    guard try await session.activate(options: []) else { return }
                } else {
                    // iOS 26 has only the synchronous API; this actor keeps it off the main thread.
                    try session.setActive(true)
                }
                active = true
            }
            try Task.checkCancellation()
            if player == nil {
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
            }
            try Task.checkCancellation()
            player?.stop()
            player?.currentTime = 0
            player?.volume = Float(min(1, volume))
            player?.play()
        } catch {
            await stop()
        }
    }

    func stop() async {
        player?.stop()
        player?.currentTime = 0
        guard active else { return }
        if #available(iOS 27.0, *) {
            _ = try? await AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation)
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        active = false
    }
}
