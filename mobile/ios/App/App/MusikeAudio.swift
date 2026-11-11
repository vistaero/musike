import AVFoundation
import Capacitor
import WebKit

/// Plays audio natively, so the music doesn't go through the web view's media stack.
///
/// WKWebView hands media to a separate process that YouTube cuts off after a few hundred kilobytes: the element
/// just pauses, with no error, about fifteen seconds in. AVPlayer uses the app's own network stack instead, which
/// reads the same URL from beginning to end. The web app drives it through the `musikeAudio` handler and gets
/// `window.__musikeAudioEvent(...)` back, so the player code doesn't have to know the difference.
final class MusikeAudio: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    /// Durations as YouTube reported them, by stream URL. AVPlayer often guesses twice the real length for these
    /// audio-only streams, which would show a seven-minute song as fourteen.
    private static var knownDurations: [String: Double] = [:]
    private var player: AVPlayer?
    private var volume: Float = 1
    private var muted = false
    private var item: AVPlayerItem?
    private var knownDuration: Double?
    /// Set once the real end was reported, so a padded stream doesn't end a second time.
    private var ended = false
    private var ticker: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?

    func attach(_ webView: WKWebView?) {
        self.webView = webView
    }

    static func remember(url: String, duration: Double) {
        guard duration > 0 else { return }
        knownDurations[url] = duration
        if knownDurations.count > 40 { knownDurations.removeAll() }
    }

    // MARK: - What the web app sends

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "musikeAudio",
              let body = message.body as? [String: Any],
              let command = body["cmd"] as? String
        else { return }

        switch command {
        case "load":
            load(body["url"] as? String ?? "", startAt: body["startAt"] as? Double ?? 0)
        case "play":
            play()
        case "pause":
            player?.pause()
        case "seek":
            seek(body["to"] as? Double ?? 0)
        case "volume":
            volume = Float(body["value"] as? Double ?? 1)
            player?.volume = volume
        case "muted":
            muted = body["value"] as? Bool ?? false
            player?.isMuted = muted
        default:
            break
        }
    }

    // MARK: - Playback

    private func load(_ link: String, startAt: Double) {
        PlaybackDiagnostics.shared.record(link.isEmpty ? "audio.load.empty" : "audio.load.start")
        tearDown()
        guard let url = URL(string: link), !link.isEmpty else {
            emit("error", ["message": "No stream"])
            return
        }
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)",
            ],
        ])
        let newItem = AVPlayerItem(asset: asset)
        knownDuration = Self.knownDurations[link]
        // Keep a visible amount ahead of the playhead, so the buffered part of the progress bar means something.
        newItem.preferredForwardBufferDuration = 30
        ended = false
        let newPlayer = AVPlayer(playerItem: newItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.volume = volume
        newPlayer.isMuted = muted
        player = newPlayer
        item = newItem

        statusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                PlaybackDiagnostics.shared.record("audio.item.ready")
                let seconds = CMTimeGetSeconds(item.duration)
                self.emit("ready", ["duration": self.duration(from: seconds)])
                if startAt > 0 { self.seek(startAt) }
            case .failed:
                PlaybackDiagnostics.shared.record("audio.item.failed \(PlaybackDiagnostics.errorCode(item.error))")
                if let log = item.errorLog()?.events.last {
                    PlaybackDiagnostics.shared.record("audio.item.error-log status=\(log.errorStatusCode)")
                }
                self.emit("error", ["message": item.error?.localizedDescription ?? "Playback failed"])
            default:
                break
            }
        }
        controlObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let state: String
            switch player.timeControlStatus {
            case .paused: state = "paused"
            case .waitingToPlayAtSpecifiedRate: state = "waiting"
            case .playing: state = "playing"
            @unknown default: state = "unknown"
            }
            PlaybackDiagnostics.shared.record("audio.control.\(state)")
            if state == "waiting" { self?.emit("waiting") }
            else if state == "playing" { self?.emit("playing") }
        }
        stalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: newItem, queue: .main) { _ in
            PlaybackDiagnostics.shared.record("audio.item.stalled")
        }
        failedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: newItem, queue: .main) { notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            PlaybackDiagnostics.shared.record("audio.item.failed-to-end \(PlaybackDiagnostics.errorCode(error))")
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: newItem, queue: .main
        ) { [weak self] _ in
            PlaybackDiagnostics.shared.record("audio.item.ended")
            self?.emit("ended")
        }
        ticker = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, let item = self.item else { return }
            let position = CMTimeGetSeconds(time)
            self.emit("time", [
                "position": position,
                "duration": self.duration(from: CMTimeGetSeconds(item.duration)),
                "buffered": self.bufferedEnd(),
            ])
            // These audio streams carry silence past the song, and AVPlayer only calls it finished at the very end
            // of the file. The track really ends where YouTube says it does.
            if let known = self.knownDuration, !self.ended, position >= known - 0.5 {
                self.ended = true
                self.player?.pause()
                self.emit("ended")
            }
        }
    }

    private func duration(from measured: Double) -> Double {
        if let knownDuration { return knownDuration }
        return measured.isFinite ? measured : 0
    }

    private func play() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            PlaybackDiagnostics.shared.record("audio.session.failed \(PlaybackDiagnostics.errorCode(error))")
        }
        PlaybackDiagnostics.shared.record("audio.play.request has-player=\(player != nil)")
        player?.play()
    }

    private func seek(_ to: Double) {
        guard let player else { return }
        player.seek(
            to: CMTime(seconds: max(0, to), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard finished else { return }
            // AVPlayer reports the old position until the seek lands; the web side waits for this.
            self?.emit("seeked", ["position": to])
        }
    }

    private func bufferedEnd() -> Double {
        guard let range = item?.loadedTimeRanges.last?.timeRangeValue else { return 0 }
        return CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
    }

    private func tearDown() {
        if let ticker { player?.removeTimeObserver(ticker) }
        ticker = nil
        statusObservation = nil
        controlObservation = nil
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
        stalledObserver = nil
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        failedObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        item = nil
    }

    private func emit(_ event: String, _ payload: [String: Any] = [:]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let js = "window.__musikeAudioEvent && window.__musikeAudioEvent('\(event)', \(json))"
        if Thread.isMainThread {
            webView?.evaluateJavaScript(js)
        } else {
            DispatchQueue.main.async { [weak self] in self?.webView?.evaluateJavaScript(js) }
        }
    }
}
