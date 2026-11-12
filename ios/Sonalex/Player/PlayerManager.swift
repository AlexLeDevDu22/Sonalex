import AVFoundation
import MediaPlayer
import Observation
import UIKit

struct QueueEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let track: Item

    init(_ track: Item) {
        id = UUID()
        self.track = track
    }

    init(id: UUID, track: Item) {
        self.id = id
        self.track = track
    }
}

enum RepeatMode: String, Codable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// AVPlayerItem that remembers which queue entry it plays.
private final class TrackItem: AVPlayerItem {
    let entryId: UUID
    let trackId: String
    let playSessionId: String
    /// End time before a Mix cut was set on this item.
    private(set) var defaultEnd: CMTime = .invalid

    /// Records the stream to the cache while it plays (the asset only holds it weakly).
    private var loader: CachingLoader?

    convenience init(url: URL, entry: QueueEntry, playSessionId: String) {
        self.init(asset: AVURLAsset(url: url), entry: entry, playSessionId: playSessionId, loader: nil)
    }

    init(asset: AVURLAsset, entry: QueueEntry, playSessionId: String, loader: CachingLoader?) {
        entryId = entry.id
        trackId = entry.track.id
        self.playSessionId = playSessionId
        self.loader = loader
        super.init(asset: asset, automaticallyLoadedAssetKeys: ["duration", "playable"])
        preferredForwardBufferDuration = 30
        // Online songs (YouTube's fragmented MP4, streamed while downloading): AVPlayer can reach
        // the last sample and just pause there instead of ending the item, so the queue never
        // moves on. An explicit end time makes AVPlayer end the item itself, a few ms before the
        // last sample — and AVQueuePlayer moves to the next song even with the screen locked.
        let known = entry.track.duration
        if entry.track.isExternal, known > 10 {
            forwardPlaybackEndTime = CMTime(seconds: known - 0.3, preferredTimescale: 600)
        }
        defaultEnd = forwardPlaybackEndTime
    }

    /// The real file is a bit shorter than the catalog says: end there instead.
    func clampEnd(to fileDuration: Double) {
        guard fileDuration.isFinite, fileDuration > 10, forwardPlaybackEndTime.isValid,
              fileDuration - 0.3 < forwardPlaybackEndTime.seconds else { return }
        let end = CMTime(seconds: fileDuration - 0.3, preferredTimescale: 600)
        if forwardPlaybackEndTime == defaultEnd { forwardPlaybackEndTime = end }
        defaultEnd = end
    }
}

/// Owns the queue and a single AVQueuePlayer. The player always holds the current track plus the
/// next one, so transitions are gapless and keep working with the screen locked.
@Observable
@MainActor
final class PlayerManager {
    static let shared = PlayerManager()

    // MARK: Public state

    private(set) var queue: [QueueEntry] = []
    private(set) var index: Int = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var sourceName: String?
    /// Identifies what started the queue (e.g. "station:<artistId>") so its card can show it's playing.
    private(set) var sourceId: String?
    /// "Lecture automatique": when the queue runs out, keep going with similar songs (endless).
    private(set) var autoplay = false
    private(set) var isLoadingRadio = false
    var showNowPlaying = false
    /// The app's playback volume on this device (iOS doesn't let apps set the system volume).
    /// Remembered, shared with the other devices and Atoll, carried over on transfers.
    var volume: Float = (UserDefaults.standard.object(forKey: "player.volume") as? Float) ?? 1 {
        didSet {
            guard volume != oldValue else { return }
            player.volume = volume
            mixEngine.volume = volume
            UserDefaults.standard.set(volume, forKey: "player.volume")
            ConnectManager.shared.reportVolume(Double(volume))
            publishPlaybackState()
        }
    }

    /// Volume of the device that plays (this one, or the one this device controls).
    var controlledVolume: Double {
        isRemote ? (ConnectManager.shared.activeDevice?.volume ?? 1) : Double(volume)
    }

    /// Sets the volume on the device that plays (forwarded when another device plays).
    func setVolume(_ level: Double) {
        let v = min(max(level, 0), 1)
        if forward(.setVolume(v)) { return }
        volume = Float(v)
    }
    var isScrubbing = false

    /// Mix: DJ-style transitions. The Pi renders each song with the transition from the previous
    /// one; MixEngine plays the pieces back to back on one audio node (gapless).
    var mixEnabled: Bool = UserDefaults.standard.bool(forKey: "player.mix") {
        didSet {
            guard mixEnabled != oldValue else { return }
            UserDefaults.standard.set(mixEnabled, forKey: "player.mix")
            switchEngine()
        }
    }
    /// 0…1 while the previous song is still blending out of the current one, and that song.
    private(set) var mixProgress: Double?
    private(set) var mixOutgoing: Item?
    @ObservationIgnored private let mixEngine = MixEngine.shared
    @ObservationIgnored private var engineSession = ""
    /// Set by next(): the song change that follows wasn't the song ending.
    @ObservationIgnored private var userAdvanced = false
    /// The Pi couldn't serve the Mix (offline…): play plainly for a while instead of retrying.
    @ObservationIgnored fileprivate var engineUnavailableUntil = Date.distantPast
    /// How far ahead the engine takes over from the plain player (grows when it came too late).
    private static let firstHandOverLead = 3.0
    @ObservationIgnored private var handOverLead = PlayerManager.firstHandOverLead
    @ObservationIgnored private var nextHandOverTry = Date.distantPast
    /// Mix mode on this device: the engine plays, AVQueuePlayer stays idle. Not offline: the
    /// Mix is made by the Pi, the songs on the device play plainly.
    private var engineMode: Bool { mixEnabled && !isRemote && !localOnlyMode && ServerFeatures.shared.companion }
    /// No connection: only songs on this device are played (set by connectivityChanged).
    @ObservationIgnored private var localOnlyMode = false
    /// The whole queue while it's cut down to the songs on the device (offline): back when online.
    @ObservationIgnored private var offlineStash: [QueueEntry]?
    /// Unstable network, and the list has songs not on the device: what to do (asked in an alert).
    var offlineChoice: OfflineChoice?
    /// The last answer to that question, reused for 15 minutes (asked once, not on every tap).
    @ObservationIgnored private var unstableAnswer: (localOnly: Bool, at: Date)?

    struct OfflineChoice: Identifiable {
        let id = UUID()
        let tracks: [Item]
        let startAt: Int
        let shuffle: Bool?
        let source: String?
        let sourceId: String?
        let autoplay: Bool
        let localCount: Int
    }

    var current: Item? { queue.indices.contains(index) ? queue[index].track : nil }

    // MARK: - Musique Connect

    /// Another device plays; this one mirrors it and forwards every action.
    var isRemote: Bool { ConnectManager.shared.isRemote }

    /// A song is loaded in this device's player (it makes or can make sound here).
    var hasLocalAudio: Bool { loadedItem != nil || mixEngine.active }

    @ObservationIgnored private var remoteBase: (time: Double, at: Double) = (0, 0)
    @ObservationIgnored private var presence: AVAudioEngine?
    /// The user wants sound. A pause AVPlayer does on its own while that's true (e.g. the Mac's
    /// output device changes) is transient: playback resumes and "playing" stays published.
    @ObservationIgnored private var wantsToPlay = false
    @ObservationIgnored private var transientPauseSince: Date?
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var remoteClock: Task<Void, Never>?

    private func forward(_ command: ConnectCommand) -> Bool {
        guard isRemote else { return false }
        ConnectManager.shared.send(command)
        return true
    }

    func connectSnapshot() -> ConnectState {
        ConnectState(queue: queue, original: originalOrder, index: index, isPlaying: isPlaying, time: currentTime,
                     timestamp: Date().timeIntervalSince1970, duration: duration, shuffle: shuffle,
                     repeatMode: repeatMode, autoplay: autoplay, source: sourceName, sourceId: sourceId,
                     volume: Double(volume))
    }

    private func adopt(_ s: ConnectState) {
        queue = s.queue
        originalOrder = s.original
        index = min(max(s.index, 0), max(s.queue.count - 1, 0))
        shuffle = s.shuffle
        repeatMode = s.repeatMode
        autoplay = s.autoplay
        sourceName = s.source
        sourceId = s.sourceId
        duration = s.duration
    }

    /// Mirror the playing device (this one stays silent).
    func applyRemote(_ s: ConnectState) {
        stopLocalAudio()
        adopt(s)
        isPlaying = s.isPlaying
        isBuffering = false
        remoteBase = (s.time + (s.isPlaying ? max(0, Date().timeIntervalSince1970 - s.timestamp) : 0),
                      Date().timeIntervalSince1970)
        currentTime = remoteBase.time
        startRemoteClock()
        updateRemotePresence()
        updateNowPlayingInfo()
        persist()
    }

    func applyRemoteProgress(time: Double?, isPlaying playing: Bool?, duration d: Double?, index i: Int?) {
        if let i, queue.indices.contains(i) { index = i }
        if let d, d > 0 { duration = d }
        if let playing { isPlaying = playing }
        if let time {
            remoteBase = (time, Date().timeIntervalSince1970)
            currentTime = time
        }
        updateRemotePresence()
        if let i, i != previousIndexForProgress { updateNowPlayingInfo() } else { updateNowPlayingPlayback() }
        previousIndexForProgress = index
    }

    @ObservationIgnored private var previousIndexForProgress = -1

    /// While another device plays, iOS only shows this app on the lock screen / Dynamic Island if
    /// it outputs audio: run a silent audio engine (like Spotify Connect) so the system player
    /// mirrors — and controls — the other device.
    private func updateRemotePresence() {
        #if !targetEnvironment(macCatalyst)
        if isRemote && isPlaying {
            guard presence == nil else { return }
            activateSession()
            let engine = AVAudioEngine()
            _ = engine.mainMixerNode // mixer → output: renders silence
            engine.prepare()
            if (try? engine.start()) != nil { presence = engine }
        } else if let engine = presence {
            engine.stop()
            presence = nil
        }
        #endif
    }

    /// Re-publishes "now playing" (macOS export included), e.g. after the device list changed.
    func refreshNowPlaying() { publishPlaybackState() }

    /// This device was picked to play: continue exactly where the other one was.
    func takeOver(_ s: ConnectState) {
        stopRemoteClock()
        presence?.stop()
        presence = nil
        adopt(s)
        let elapsed = s.isPlaying ? max(0, Date().timeIntervalSince1970 - s.timestamp) : 0
        if let v = s.volume { volume = Float(v) } // keep the level the other device was playing at
        currentTime = s.time + elapsed
        loadCurrent(autoplay: s.isPlaying, at: currentTime)
        persist()
    }

    /// Another device took over playback: stop the sound here, keep the queue.
    func releaseToRemote() {
        stopLocalAudio()
        isPlaying = false
    }

    /// The playing device went away: back to a normal, idle local player on the same queue.
    func remoteEnded() {
        stopRemoteClock()
        isPlaying = false
        updateRemotePresence()
        updateNowPlayingInfo()
        persist()
    }

    /// Runs an action received from a remote device.
    func execute(_ command: ConnectCommand) {
        switch command {
        case .play: play()
        case .pause: pause()
        case .toggle: togglePlayPause()
        case .next: next()
        case .previous: previous()
        case .seek(let t): seek(to: t)
        case .jump(let id): jump(to: id)
        case let .playTracks(tracks, startAt, shuffle, source, sourceId, autoplay):
            play(tracks, startAt: startAt, shuffle: shuffle, source: source, sourceId: sourceId, autoplay: autoplay)
        case .playNext(let tracks): playNext(tracks)
        case .addToQueue(let tracks): addToQueue(tracks)
        case .remove(let ids):
            let offsets = IndexSet(upcoming.enumerated().filter { ids.contains($0.element.id) }.map(\.offset))
            removeUpcoming(at: offsets)
        case let .move(from, to): moveUpcoming(from: IndexSet(from), to: to)
        case .clearUpcoming: clearUpcoming()
        case .toggleShuffle: toggleShuffle()
        case .setRepeat(let mode): setRepeat(mode)
        case .toggleAutoplay: toggleAutoplay()
        case .setVolume(let v): setVolume(v)
        }
    }

    private func stopLocalAudio() {
        wantsToPlay = false
        if mixEngine.active { mixEngine.stop() }
        guard loadedItem != nil || player.currentItem != nil else { return }
        reportStoppedIfNeeded()
        player.pause()
        player.removeAllItems()
        loadedItem = nil
        endLoadingTask()
    }

    /// The remote's position moves on its own between progress messages.
    private func startRemoteClock() {
        guard remoteClock == nil else { return }
        remoteClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isRemote else { continue }
                if self.isPlaying, !self.isScrubbing {
                    let t = self.remoteBase.time + Date().timeIntervalSince1970 - self.remoteBase.at
                    self.currentTime = self.duration > 0 ? min(t, self.duration) : t
                }
            }
        }
    }

    private func stopRemoteClock() {
        remoteClock?.cancel()
        remoteClock = nil
    }

    /// True when the queue was started from this album / playlist / artist (or its station).
    func isQueueSource(_ item: Item) -> Bool {
        guard let sourceId, current != nil else { return false }
        return sourceId == item.playbackSourceId || (item.isArtist && sourceId == "station:\(item.id)")
    }
    var currentEntry: QueueEntry? { queue.indices.contains(index) ? queue[index] : nil }
    var upcoming: [QueueEntry] { queue.indices.contains(index) ? Array(queue[(index + 1)...]) : [] }

    // MARK: Private

    private let player = AVQueuePlayer()
    @ObservationIgnored private var originalOrder: [QueueEntry]?
    @ObservationIgnored private var loadedItem: TrackItem?
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var ignoreTicksUntil = Date.distantPast
    @ObservationIgnored private var lastProgressReport = Date.distantPast
    @ObservationIgnored private var lastTimeSave = Date.distantPast
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var nextStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var artwork: (id: String, art: MPMediaItemArtwork)?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkLoadingId: String?
    @ObservationIgnored private var lastNowPlayingRefresh = Date.distantPast
    /// Keeps the app awake while a song loads in the background (else iOS may suspend it
    /// before audio starts, and playback silently stops).
    @ObservationIgnored private var loadingTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var failureCount = 0
    /// End-of-track watchdog (see checkStuckAtEnd).
    @ObservationIgnored private var endWatchdog: Timer?
    @ObservationIgnored private var watchedTime: Double = -1
    @ObservationIgnored private var stuckSince: Date?
    /// Playback watchdog (see checkPlayback): last position seen, since when, recoveries tried.
    @ObservationIgnored private var stall: Stall?
    private struct Stall {
        let entry: UUID
        var position: Double?
        var since: Date
        var played: Double = 0  // really played since the last recovery (jumps = seeks don't count)
        var strikes = 0
    }
    /// The player volume fade in progress (nil = none: the volume must be the app volume).
    @ObservationIgnored private var playerRamp: UUID?

    private let api = JellyfinClient.shared

    private init() {
        configureAudioSession()
        player.actionAtItemEnd = .advance
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = true

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.timeControlChanged() }
        })
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    // A call, Siri…: the Mix engine is stopped by the system too. What was playing
                    // comes back afterwards; what was paused stays paused.
                    self.resumeAfterInterruption = self.wantsToPlay
                    self.wantsToPlay = false
                    self.sessionActive = false
                    if self.mixEngine.active { self.mixEngine.pause() }
                }
                if type == .ended, options.contains(.shouldResume), self.resumeAfterInterruption {
                    self.resumeAfterInterruption = false
                    self.play()
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            MainActor.assumeIsolated {
                guard let self, !self.isRemote else { return }
                if reason == .oldDeviceUnavailable {
                    // Headphones unplugged: pausing is what people expect. AVPlayer does it by
                    // itself; the Mix engine would carry on out of the speakers.
                    if self.mixEngine.active {
                        self.pause()
                    } else {
                        self.wantsToPlay = false
                        self.timeControlChanged()
                    }
                } else if self.wantsToPlay, self.player.timeControlStatus == .paused, self.loadedItem != nil {
                    // New output (speakers, multi-output device…): keep going.
                    self.activateSession()
                    self.player.play()
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionActive = false
                self?.configureAudioSession()
                self?.reloadCurrent(autoplay: false)
            }
        }
        nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = note.object as? TrackItem
            MainActor.assumeIsolated {
                guard let self else { return }
                PlayerDiagnostics.log("didPlayToEnd", ["item": ended?.trackId ?? "?", "current": ended === self.loadedItem,
                                                       "items": self.player.items().count])
            }
        }
        nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let failed = note.object as? AVPlayerItem
            let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated {
                PlayerDiagnostics.log("failedToPlayToEnd", ["error": error ?? "?", "current": failed === self?.loadedItem])
                guard let self, let failed, failed === self.loadedItem else { return }
                self.handleFailure()
            }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist() }
        }

        endWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkStuckAtEnd()
                self?.checkPlayback()
                self?.retryHandOverIfNeeded()
            }
        }

        setupRemoteCommands()
        restore()
        connectMixEngine()
    }

    /// Online songs are fragmented MP4 (YouTube's DASH audio) streamed progressively: AVPlayer
    /// sometimes plays the last fragment and then waits forever instead of ending the item, so
    /// the queue never moves on. If we want to play, time hasn't moved for 3 s and we're within
    /// a few seconds of the end, treat the track as finished.
    private func checkStuckAtEnd() {
        guard wantsToPlay, !isRemote, !isScrubbing, pendingSeek == nil,
              let loaded = loadedItem, player.currentItem === loaded else {
            stuckSince = nil
            watchedTime = -1
            return
        }
        let t = player.currentTime().seconds
        let ends = [duration, loaded.duration.seconds].filter { $0.isFinite && $0 > 5 }
        guard t.isFinite, let end = ends.min(), t >= end - 5 else {
            stuckSince = nil
            watchedTime = t
            return
        }
        if abs(t - watchedTime) > 0.2 {  // still moving
            stuckSince = nil
        } else if stuckSince == nil {
            stuckSince = Date()
        } else if let since = stuckSince, Date().timeIntervalSince(since) >= 2 {
            stuckSince = nil
            watchedTime = -1
            PlayerDiagnostics.log("watchdog", ["t": t, "end": end, "status": player.timeControlStatus.rawValue])
            finishStuckTrack()
            return
        }
        watchedTime = t
    }

    /// Within a few seconds of the end of the current song.
    private var isNearEnd: Bool {
        guard let loaded = loadedItem else { return false }
        let t = player.currentTime().seconds
        let ends = [duration, loaded.duration.seconds].filter { $0.isFinite && $0 > 5 }
        guard t.isFinite, let end = ends.min() else { return false }
        return t >= end - 3
    }

    private func finishStuckTrack() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            return
        }
        if index + 1 < queue.count || repeatMode == .all {
            next()
            // next() keeps "playing" only if it was: make sure the new track starts.
            if !isPlaying { play() }
        } else {
            // Last song of the queue: stop cleanly at the end.
            wantsToPlay = false
            player.pause()
            seek(to: 0)
        }
    }

    /// Every second, whatever went wrong before: music that should play does play.
    /// - Outside a fade, the output is at the app volume (a fade planned for one song once landed
    ///   on the next one after a skip: it played on, silent).
    /// - Nothing moves for 12 s although we want to play (stream stuck, Mix starved, player
    ///   waiting forever…): reload the song where it is (fresh stream, plain player if the Mix was
    ///   the one stuck). Still nothing 12 s later: next song. Never an endless spinner.
    private func checkPlayback() {
        guard !isRemote else { stall = nil; return }
        if !mixEngine.active, loadedItem != nil, playerRamp == nil, abs(player.volume - volume) > 0.01 {
            PlayerDiagnostics.log("volumeRepaired", ["was": player.volume])
            player.volume = volume
        }
        mixEngine.repairVolumeIfNeeded()
        if let t = pendingSeek, let loaded = loadedItem, loaded.status == .readyToPlay {
            // Ready without us hearing about it: a pending seek would freeze the clock.
            pendingSeek = nil
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }

        guard wantsToPlay, !isScrubbing, let entry = currentEntry else { stall = nil; return }
        let position: Double?
        if let loaded = loadedItem, player.currentItem === loaded {
            let t = player.currentTime().seconds
            position = t.isFinite ? t : nil
        } else if mixEngine.active {
            position = mixEngine.playedSeconds
        } else {
            position = nil  // nothing loaded at all
        }
        let now = Date()
        guard var s = stall, s.entry == entry.id else {
            stall = Stall(entry: entry.id, position: position, since: now)
            return
        }
        if let p = position {
            let step = s.position.map { abs(p - $0) } ?? 0
            if s.position == nil || step > 0.3 {  // moving
                s.position = p
                s.since = now
                if step < 5 { s.played += step }
                if s.played > 3 { s.strikes = 0 }
                stall = s
                return
            }
        }
        guard now.timeIntervalSince(s.since) >= 12 else { return }
        s.strikes += 1
        s.since = now
        s.played = 0
        stall = s
        PlayerDiagnostics.log("stalled", ["strikes": s.strikes, "engine": mixEngine.active, "loaded": loadedItem != nil,
                                          "status": player.timeControlStatus.rawValue,
                                          "waiting": player.reasonForWaitingToPlay?.rawValue ?? "",
                                          "itemStatus": loadedItem?.status.rawValue ?? -1])
        if s.strikes == 1 {
            if mixEngine.active { engineUnavailableUntil = now.addingTimeInterval(120) }
            loadCurrent(autoplay: true, at: currentTime)
            return
        }
        stall = nil
        if index + 1 < queue.count || repeatMode == .all {
            ToastCenter.shared.show("This song won’t start: skipping to the next one", systemImage: "forward.fill")
            index = index + 1 < queue.count ? index + 1 : 0
            loadCurrent(autoplay: true)
            persist()
        } else {
            ToastCenter.shared.show("This song won’t start", systemImage: "exclamationmark.triangle.fill")
            mixEngine.stop()
            reportStoppedIfNeeded()
            player.pause()
            player.removeAllItems()
            loadedItem = nil
            wantsToPlay = false
            isPlaying = false
            isBuffering = false
            endLoadingTask()
            updateNowPlayingPlayback()
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    /// setActive can block for a while (Apple warns about it on the main thread): done once, on a
    /// background queue. AVPlayer starts as soon as the session is up.
    @ObservationIgnored private var sessionActive = false
    private static let sessionQueue = DispatchQueue(label: "musique.audiosession", qos: .userInitiated)

    private func activateSession() {
        guard !sessionActive else { return }
        sessionActive = true
        Self.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    // MARK: - Public API

    /// Replace the queue and start playing. `shuffle: true` = shuffle button, `false` = play button,
    /// `nil` = a tap on a track (keeps the current shuffle setting).
    func play(_ tracks: [Item], startAt: Int = 0, shuffle: Bool? = nil, source: String? = nil, sourceId: String? = nil,
              autoplay: Bool = false) {
        if forward(.playTracks(tracks: tracks, startAt: startAt, shuffle: shuffle, source: source, sourceId: sourceId, autoplay: autoplay)) { return }
        startPlaying(tracks, startAt: startAt, shuffle: shuffle, source: source, sourceId: sourceId, autoplay: autoplay,
                     localOnly: nil)
    }

    /// The answer to the "unstable network" question.
    func resolveOfflineChoice(localOnly: Bool) {
        guard let c = offlineChoice else { return }
        offlineChoice = nil
        unstableAnswer = (localOnly, Date())
        startPlaying(c.tracks, startAt: c.startAt, shuffle: c.shuffle, source: c.source, sourceId: c.sourceId,
                     autoplay: c.autoplay, localOnly: localOnly)
    }

    /// On this device (downloaded, or fully recorded while it streamed): plays without network.
    func isPlayableOffline(_ track: Item) -> Bool {
        !track.isExternal && (OfflineStore.shared.localURL(for: track) != nil
                              || StreamCache.shared.completeFile(for: track.id) != nil)
    }

    /// `localOnly`: nil = decide from the connection. Online: everything, as usual. Offline: only
    /// the songs on the device, without trying the network. Unstable: ask (once in a while).
    private func startPlaying(_ tracks: [Item], startAt: Int, shuffle: Bool?, source: String?, sourceId: String?,
                              autoplay: Bool, localOnly: Bool?) {
        let playable = tracks.filter { $0.isSong || $0.type == nil }
        guard !playable.isEmpty else { return }
        var localOnly = localOnly
        if localOnly == nil {
            let localCount = playable.filter(isPlayableOffline).count
            if localCount == playable.count {
                localOnly = false
            } else {
                switch Connectivity.shared.status {
                case .online:
                    localOnly = false
                case .offline:
                    guard localCount > 0 else {
                        ToastCenter.shared.show("No connection, and none of these songs are downloaded", systemImage: "wifi.slash")
                        return
                    }
                    localOnly = true
                case .unstable:
                    if localCount == 0 {
                        localOnly = false
                    } else if let answer = unstableAnswer, Date().timeIntervalSince(answer.at) < 15 * 60 {
                        localOnly = answer.localOnly
                    } else {
                        offlineChoice = OfflineChoice(tracks: tracks, startAt: startAt, shuffle: shuffle, source: source,
                                                      sourceId: sourceId, autoplay: autoplay, localCount: localCount)
                        return
                    }
                }
            }
        }
        var entries = playable.map(QueueEntry.init)
        var start = min(max(startAt, 0), entries.count - 1)
        // startAt refers to the unfiltered list; map it onto the filtered one.
        if playable.count != tracks.count, tracks.indices.contains(startAt),
           let i = playable.firstIndex(where: { $0.id == tracks[startAt].id }) {
            start = i
        }
        let wantShuffle = shuffle ?? self.shuffle
        if wantShuffle {
            originalOrder = entries
            if shuffle == true {
                // Shuffle button: smart order for the whole list.
                entries = SmartShuffle.order(entries)
            } else {
                // A tap on a song while shuffle is on: that song first, the rest in smart order.
                let first = entries[start]
                entries = [first] + SmartShuffle.order(entries.filter { $0.id != first.id })
            }
            start = 0
        } else {
            originalOrder = nil
        }
        self.shuffle = wantShuffle
        offlineStash = nil
        if localOnly == true {
            // Only what's on the device; the tapped song, or the first one after it that is.
            let full = entries
            let order = Array(full[start...]) + Array(full[..<start])
            let first = order.first { isPlayableOffline($0.track) }
            entries = full.filter { isPlayableOffline($0.track) }
            originalOrder = originalOrder?.filter { isPlayableOffline($0.track) }
            start = first.flatMap { f in entries.firstIndex(of: f) } ?? 0
            offlineStash = full
            ToastCenter.shared.show(Connectivity.shared.isOffline ? "No connection: playing downloaded songs"
                                                                  : "Playing downloaded songs only",
                                    systemImage: "arrow.down.circle")
        }
        queue = entries
        index = start
        sourceName = source
        self.sourceId = sourceId
        RecentSources.shared.played(sourceId)
        self.autoplay = autoplay
        failureCount = 0
        loadCurrent(autoplay: true)
        persist()
    }

    /// The connection came and went. Offline: the Mix steps aside (it's made by the Pi) and the
    /// rest of the queue keeps only the songs on the device. Back online: the whole queue again.
    func connectivityChanged(from old: Connectivity.Status, to new: Connectivity.Status) {
        guard !isRemote else { return }
        if new == .offline {
            guard !localOnlyMode else { return }
            localOnlyMode = true
            if mixEngine.active {
                if isPlaying, let point = mixEngine.handoffPoint(minLead: 1.5) {
                    handOverToPlayer(point, fallback: true)
                } else {
                    let wasPlaying = isPlaying, t = currentTime
                    mixEngine.stop()
                    mixProgress = nil
                    mixOutgoing = nil
                    loadCurrent(autoplay: wasPlaying, at: t)
                }
            }
            keepOnlyLocalSongs()
        } else if old == .offline {
            localOnlyMode = false
            restoreFullQueue()
        }
    }

    private func keepOnlyLocalSongs() {
        guard !queue.isEmpty else { return }
        let drop = Set(queue.indices.filter { $0 > index && !isPlayableOffline(queue[$0].track) }.map { queue[$0].id })
        guard !drop.isEmpty else { return }
        if offlineStash == nil { offlineStash = queue }
        queue.removeAll { drop.contains($0.id) }
        originalOrder = originalOrder?.filter { !drop.contains($0.id) }
        refreshNextItem()
        persist()
        ToastCenter.shared.show("No connection: up next is limited to downloaded songs", systemImage: "wifi.slash")
    }

    private func restoreFullQueue() {
        guard let stash = offlineStash else { return }
        offlineStash = nil
        guard let cur = currentEntry, let i = stash.firstIndex(of: cur) else { return }
        // Songs added meanwhile stay, right after the current one.
        let known = Set(stash.map(\.id))
        let added = queue.filter { !known.contains($0.id) }
        var full = stash
        full.insert(contentsOf: added, at: i + 1)
        queue = full
        index = i
        refreshNextItem()
        persist()
        ToastCenter.shared.show("Back online: the whole queue is back", systemImage: "wifi")
    }

    func toggleAutoplay() {
        if forward(.toggleAutoplay) { return }
        autoplay.toggle()
        queueDidChange()
        persist()
    }

    /// An online song was just saved to the library: use the Jellyfin item from now on
    /// (favorites, playlists…), without interrupting playback.
    func replaceTrack(key: String, with item: Item) {
        func swap(_ entries: [QueueEntry]) -> [QueueEntry] {
            entries.map { $0.track.externalKey == key ? QueueEntry(id: $0.id, track: item) : $0 }
        }
        queue = swap(queue)
        originalOrder = originalOrder.map(swap)
        persist()
    }

    func togglePlayPause() {
        if forward(.toggle) { return }
        if engineMode { isPlaying ? pause() : play(); return }
        if player.timeControlStatus == .paused { play() } else { pause() }
    }

    func play() {
        if forward(.play) { return }
        guard current != nil else { return }
        #if !targetEnvironment(macCatalyst)
        StayReachable.shared.stop()
        #endif
        activateSession()
        if engineMode {
            ConnectManager.shared.claimIfNeeded()
            wantsToPlay = true
            if mixEngine.active { mixEngine.play() } else { loadCurrent(autoplay: true, at: currentTime) }
            return
        }
        if player.currentItem == nil || loadedItem == nil {
            loadCurrent(autoplay: true, at: currentTime)
        } else {
            ConnectManager.shared.claimIfNeeded()
            wantsToPlay = true
            player.play()
        }
    }

    func pause() {
        if forward(.pause) { return }
        wantsToPlay = false
        #if !targetEnvironment(macCatalyst)
        StayReachable.shared.paused()  // the Mac can still say "play" to this iPhone
        #endif
        if engineMode {
            mixEngine.pause()
            if loadedItem != nil { player.pause() }  // still handing over to the engine
            persist()
            return
        }
        player.pause()
        persist()
    }

    func next() {
        if forward(.next) { return }
        guard !queue.isEmpty else { return }
        if let track = current, duration > 0, currentTime < duration * 0.8 {
            PlayStats.shared.skipped(track)
        }
        userAdvanced = true
        let wasPlaying = isPlaying
        if repeatMode != .one, !mixEngine.active, player.items().count > 1, index + 1 < queue.count {
            // The next track is already buffered: let AVQueuePlayer switch instantly.
            player.advanceToNextItem()
            return
        }
        if index + 1 < queue.count {
            index += 1
            loadCurrent(autoplay: wasPlaying)
        } else {
            index = 0
            loadCurrent(autoplay: repeatMode == .all && wasPlaying)
        }
        persist()
    }

    func previous() {
        if forward(.previous) { return }
        guard !queue.isEmpty else { return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
            return
        }
        index -= 1
        loadCurrent(autoplay: isPlaying)
        persist()
    }

    func seek(to seconds: Double) {
        if isRemote {
            currentTime = seconds
            remoteBase = (seconds, Date().timeIntervalSince1970)
            ConnectManager.shared.send(.seek(seconds))
            return
        }
        if engineMode, loadedItem == nil {
            currentTime = max(0, seconds)
            loadCurrent(autoplay: isPlaying, at: currentTime)
            updateNowPlayingPlayback()
            return
        }
        let t = max(0, min(seconds, duration > 0 ? duration - 0.5 : seconds))
        currentTime = t
        ignoreTicksUntil = Date().addingTimeInterval(0.4)
        if let item = player.currentItem, item.status == .readyToPlay {
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.updateNowPlayingPlayback() }
            }
        } else {
            pendingSeek = t
        }
        updateNowPlayingPlayback()
    }

    func jump(to entryId: UUID) {
        if forward(.jump(entryId)) { return }
        guard let i = queue.firstIndex(where: { $0.id == entryId }) else { return }
        index = i
        loadCurrent(autoplay: true)
        persist()
    }

    func playNext(_ tracks: [Item]) {
        if forward(.playNext(tracks)) { return }
        let entries = tracks.filter(\.isSong).map(QueueEntry.init)
        guard !entries.isEmpty else { return }
        if queue.isEmpty { play(tracks); return }
        queue.insert(contentsOf: entries, at: index + 1)
        if var orig = originalOrder, let cur = currentEntry, let pos = orig.firstIndex(of: cur) {
            orig.insert(contentsOf: entries, at: pos + 1)
            originalOrder = orig
        }
        refreshNextItem()
        persist()
    }

    func addToQueue(_ tracks: [Item]) {
        if forward(.addToQueue(tracks)) { return }
        let entries = tracks.filter(\.isSong).map(QueueEntry.init)
        guard !entries.isEmpty else { return }
        if queue.isEmpty { play(tracks); return }
        queue.append(contentsOf: entries)
        originalOrder?.append(contentsOf: entries)
        refreshNextItem()
        persist()
    }

    /// Offsets are relative to `upcoming`.
    func removeUpcoming(at offsets: IndexSet) {
        let list = upcoming
        let ids = offsets.filter { list.indices.contains($0) }.map { list[$0].id }
        if forward(.remove(ids)) { return }
        queue.removeAll { ids.contains($0.id) }
        originalOrder?.removeAll { ids.contains($0.id) }
        refreshNextItem()
        persist()
    }

    func removeUpcoming(id: UUID) {
        guard let i = upcoming.firstIndex(where: { $0.id == id }) else { return }
        removeUpcoming(at: IndexSet(integer: i))
    }

    /// Offsets are relative to `upcoming`.
    func moveUpcoming(from source: IndexSet, to destination: Int) {
        if forward(.move(from: Array(source), to: destination)) { return }
        guard queue.indices.contains(index) else { return }
        var up = upcoming
        // From another device, whose list may be a step behind: out-of-range offsets would crash.
        let valid = IndexSet(source.filter { up.indices.contains($0) })
        guard !valid.isEmpty else { return }
        up.move(fromOffsets: valid, toOffset: min(max(destination, 0), up.count))
        queue = Array(queue[...index]) + up
        refreshNextItem()
        persist()
    }

    func clearUpcoming() {
        if forward(.clearUpcoming) { return }
        guard queue.indices.contains(index) else { return }
        let removed = Set(upcoming.map(\.id))
        queue = Array(queue[...index])
        originalOrder?.removeAll { removed.contains($0.id) }
        refreshNextItem()
        persist()
    }

    func toggleShuffle() {
        if forward(.toggleShuffle) { return }
        if queue.isEmpty { shuffle.toggle(); return }
        if shuffle {
            if let orig = originalOrder, let cur = currentEntry {
                queue = orig
                index = orig.firstIndex(of: cur) ?? 0
            }
            originalOrder = nil
            shuffle = false
        } else {
            originalOrder = queue
            let head = Array(queue[...index])
            queue = head + SmartShuffle.order(upcoming)
            shuffle = true
        }
        refreshNextItem()
        syncRemoteCommandState()
        persist()
    }

    func cycleRepeat() {
        setRepeat(repeatMode.next)
    }

    func setRepeat(_ mode: RepeatMode) {
        if forward(.setRepeat(mode)) { return }
        repeatMode = mode
        refreshNextItem()
        syncRemoteCommandState()
        persist()
    }

    func reset() {
        stopLocalAudio()
        isBuffering = false
        mixProgress = nil
        mixOutgoing = nil
        offlineStash = nil
        queue = []
        originalOrder = nil
        index = 0
        currentTime = 0
        duration = 0
        isPlaying = false
        showNowPlaying = false
        sourceName = nil
        sourceId = nil
        autoplay = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? FileManager.default.removeItem(at: Self.saveURL)
        UserDefaults.standard.removeObject(forKey: Self.timeKey)
    }

    // MARK: - Loading

    private func makeItem(for entry: QueueEntry) -> TrackItem? {
        let sid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let item: TrackItem
        if let local = OfflineStore.shared.localURL(for: entry.track) ?? StreamCache.shared.completeFile(for: entry.track.id),
           !entry.track.isExternal {
            // On this device: starts at once, works offline.
            item = TrackItem(url: local, entry: entry, playSessionId: sid)
        } else if !entry.track.isExternal, let remote = api.fileURL(for: entry.track) {
            // Streamed and recorded at the same time: replays are instant, and a favourite heard to
            // the end can stay on the device without downloading it again.
            let (asset, loader) = StreamCache.shared.asset(for: entry.track.id, remote: remote)
            item = TrackItem(asset: asset, entry: entry, playSessionId: sid, loader: loader)
        } else {
            let url = entry.track.externalKey.flatMap { SonalexAPI.shared.streamURL(for: $0) }
                ?? api.streamURL(for: entry.track, playSessionId: sid)
            guard let url else { return nil }
            item = TrackItem(url: url, entry: entry, playSessionId: sid)
        }
        AmbilightTap.attachIfEnabled(item)
        return item
    }

    /// Items currently loaded in AVQueuePlayer (current + preloaded next).
    func playerItems() -> [AVPlayerItem] { player.items() }

    private func loadCurrent(autoplay: Bool, at time: Double = 0) {
        if localOnlyMode, let entry = currentEntry, !isPlayableOffline(entry.track) {
            // No connection: never wait on the network, go to the next song on the device.
            if let i = queue.indices.first(where: { $0 > index && isPlayableOffline(queue[$0].track) }) {
                index = i
                return loadCurrent(autoplay: autoplay)
            }
            reportStoppedIfNeeded()
            if mixEngine.active { mixEngine.stop() }
            player.removeAllItems()
            loadedItem = nil
            wantsToPlay = false
            isPlaying = false
            isBuffering = false
            ToastCenter.shared.show("No connection: no more downloaded songs in the queue", systemImage: "wifi.slash")
            return
        }
        userAdvanced = false
        handOverLead = Self.firstHandOverLead
        mixProgress = nil
        mixOutgoing = nil
        reportStoppedIfNeeded()
        player.removeAllItems()
        loadedItem = nil
        // One song at a time, at full volume: whatever was playing or handing over (engine, a
        // fade planned for the previous song) stops here.
        if mixEngine.active { mixEngine.stop() }
        playerRamp = nil
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = true
        // Mix mode, playing: start at once with the plain player (local file / direct stream), the
        // Mix engine takes over in sync a few seconds later (no waiting for the Pi to render).
        var thenHandOver = false
        if engineMode, autoplay, let entry = currentEntry, entry.track.duration - time > 10,
           Date() > engineUnavailableUntil {
            mixEngine.stop()
            thenHandOver = true
        }
        // The Pi failed lately: plain player for a while (Jellyfin direct), the Mix comes back after.
        if engineMode, !thenHandOver, Date() > engineUnavailableUntil {
            guard let entry = currentEntry else { isPlaying = false; return }
            PlayerDiagnostics.log("engineLoad", ["from": time, "autoplay": autoplay])
            currentTime = time
            duration = entry.track.duration
            if autoplay {
                activateSession()
                ConnectManager.shared.claimIfNeeded()
                wantsToPlay = true
                ListeningHistory.shared.record(entry.track)
            }
            engineStarted(entry, at: time, paused: !autoplay)
            mixEngine.start(entryId: entry.id, at: time, autoplay: autoplay)
            updateNowPlayingInfo()
            queueDidChange()
            return
        }
        guard let entry = currentEntry, let item = makeItem(for: entry) else {
            isPlaying = false
            return
        }
        loadedItem = item
        player.insert(item, after: nil)
        observeStatus(of: item)
        pendingSeek = time > 0.5 ? time : nil
        currentTime = time
        duration = entry.track.duration
        refreshNextItem()
        api.reportStart(entry.track.id, sid: item.playSessionId, seconds: time, paused: !autoplay)
        if autoplay { ListeningHistory.shared.record(entry.track) }
        updateNowPlayingInfo()
        if autoplay {
            activateSession()
            // Show the spinner right away, not when AVPlayer gets round to saying it's waiting.
            isBuffering = true
            beginLoadingTask()
            ConnectManager.shared.claimIfNeeded()
            wantsToPlay = true
            player.play()
        } else {
            wantsToPlay = false
            player.pause()
        }
        if thenHandOver, let entry = currentEntry { handOverToEngine(item: item, entry: entry) }
    }

    private func reloadCurrent(autoplay: Bool) {
        guard current != nil else { return }
        loadCurrent(autoplay: autoplay, at: currentTime)
    }

    private func nextIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        if repeatMode == .one { return index }
        if index + 1 < queue.count { return index + 1 }
        if repeatMode == .all { return 0 }
        return nil
    }

    /// Makes sure the item right after the current one in AVQueuePlayer matches the queue.
    private func refreshNextItem() {
        defer { queueDidChange() }
        prefetchNextArtwork()
        if engineMode { mixEngine.queueChanged(); return }
        let items = player.items()
        guard let head = items.first as? TrackItem, head === loadedItem else { return }
        let wanted = nextIndex().map { queue[$0] }
        if items.count == 2, let second = items[1] as? TrackItem, let wanted, second.entryId == wanted.id,
           repeatMode != .one || second !== head {
            return
        }
        for extra in items.dropFirst() { player.remove(extra) }
        if let wanted, let item = makeItem(for: wanted), player.canInsert(item, after: head) {
            player.insert(item, after: head)
            nextStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.itemStatusChanged(item) }
            }
        }
    }

    /// After any queue / track change: let the Pi prepare the next online songs, and top the
    /// queue up with recommendations when autoplay is on and it's about to run out.
    private func queueDidChange() {
        let keys = upcoming.prefix(3).compactMap(\.track.externalKey)
        if !keys.isEmpty { SonalexAPI.shared.prepare(keys) }

        // Endless: as soon as fewer than 5 songs remain, fetch more (never songs already in the
        // queue or heard recently — the Pi gets your last 150 songs to skip).
        guard autoplay, ServerFeatures.shared.online, !isRemote, !isLoadingRadio, upcoming.count < 5,
              let seed = current else { return }
        isLoadingRadio = true
        let inQueue = queue.suffix(150).map { (title: $0.track.title, artist: $0.track.firstArtist?.name ?? $0.track.artistLine) }
        let recent = ListeningHistory.shared.recent(150) + inQueue
        Task {
            defer { isLoadingRadio = false }
            guard let more = try? await SonalexAPI.shared.radio(seed: seed, recent: recent, limit: 25) else { return }
            var known = Set(queue.map { ListeningHistory.signature($0.track) })
            let entries = more.filter { known.insert(ListeningHistory.signature($0)).inserted }.map(QueueEntry.init)
            guard autoplay, !entries.isEmpty else { return }
            queue.append(contentsOf: entries)
            originalOrder?.append(contentsOf: entries)
            refreshNextItem()
            persist()
        }
    }

    private func observeStatus(of item: TrackItem) {
        // .initial: an item can be ready before we start observing it (local files, hand-overs).
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item) }
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        if item.status == .failed {
            PlayerDiagnostics.log("itemFailed", ["current": item === loadedItem,
                                                 "error": item.error?.localizedDescription ?? "?"])
        }
        guard item === loadedItem else { return }
        switch item.status {
        case .readyToPlay:
            failureCount = 0
            let d = item.duration.seconds
            (item as? TrackItem)?.clampEnd(to: d)
            // Jellyfin's duration (ffprobe) is exact; AVPlayer's can be an estimate. Online songs:
            // take AVPlayer's only when it's plausible next to the catalog's.
            if d.isFinite, d > 0, duration <= 0 || (current?.isExternal == true && abs(d - duration) < max(20, duration * 0.25)) {
                duration = d
            }
            if let t = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            updateNowPlayingInfo()
        case .failed:
            handleFailure()
        default:
            break
        }
    }

    private func handleFailure() {
        failureCount += 1
        ToastCenter.shared.show("Can’t play this song", systemImage: "exclamationmark.triangle.fill")
        guard failureCount < 3, queue.count > 1 else {
            wantsToPlay = false
            player.pause()
            loadedItem = nil
            player.removeAllItems()
            isPlaying = false
            return
        }
        index = (index + 1) % queue.count
        loadCurrent(autoplay: true)
    }

    // MARK: - Player callbacks

    private func currentItemChanged() {
        guard let item = player.currentItem as? TrackItem else {
            // We emptied the player ourselves (hand-over to the Mix, new song): nothing ended.
            guard loadedItem != nil else { return }
            if let loaded = loadedItem, player.items().isEmpty, wantsToPlay,
               let i = queue.firstIndex(where: { $0.id == loaded.entryId }),
               i + 1 < queue.count || repeatMode == .all {
                // AVPlayer ran out but OUR queue didn't: the preloaded next song had failed or been
                // dropped. Load it now instead of stopping.
                PlayerDiagnostics.log("ranOutButQueueHasMore", ["index": i, "queue": queue.count])
                reportStoppedIfNeeded(finished: true)
                index = i + 1 < queue.count ? i + 1 : 0
                loadCurrent(autoplay: true)
                persist()
                return
            }
            // The queue ran out (end of the last track without repeat).
            PlayerDiagnostics.log("queueEnded", ["queue": queue.count, "index": index])
            if let finished = current { OfflineStore.shared.listenedToEnd(finished) }
            if let loaded = loadedItem, player.items().isEmpty {
                wantsToPlay = false
                player.pause()  // else AVPlayer keeps "waiting to play" (the endless spinner)
                api.reportStopped(loaded.trackId, sid: loaded.playSessionId, seconds: duration)
                loadedItem = nil
                isPlaying = false
                isBuffering = false
                endLoadingTask()
                currentTime = 0
                updateNowPlayingPlayback()
                persist()
                ToastCenter.shared.show("End of the queue", systemImage: "stop.circle")
            }
            return
        }
        guard item !== loadedItem else { return }

        // AVQueuePlayer advanced on its own (track finished or `next()`).
        if !userAdvanced, let finished = current { OfflineStore.shared.listenedToEnd(finished) }
        userAdvanced = false
        PlayerDiagnostics.log("advanced", ["to": item.trackId, "items": player.items().count])
        reportStoppedIfNeeded(finished: true)
        loadedItem = item
        observeStatus(of: item)
        if let i = queue.firstIndex(where: { $0.id == item.entryId }) { index = i }
        currentTime = 0
        pendingSeek = nil
        duration = current?.duration ?? 0
        let d = item.duration.seconds
        if d.isFinite, d > 0, duration <= 0 || (current?.isExternal == true && abs(d - duration) < max(20, duration * 0.25)) {
            duration = d
        }
        api.reportStart(item.trackId, sid: item.playSessionId, seconds: 0, paused: false)
        if let track = current { ListeningHistory.shared.record(track) }
        refreshNextItem()
        updateNowPlayingInfo()
        persist()
    }

    private func handleTransientPause() {
        if transientPauseSince == nil { transientPauseSince = Date() }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard wantsToPlay, player.timeControlStatus == .paused, let since = transientPauseSince else { return }
            if Date().timeIntervalSince(since) < 4 {
                activateSession()
                player.play()
            } else {
                // It really stopped: say so.
                wantsToPlay = false
                transientPauseSince = nil
                timeControlChanged()
            }
        }
    }

    private func beginLoadingTask() {
        guard loadingTask == .invalid else { return }
        loadingTask = UIApplication.shared.beginBackgroundTask(withName: "Loading song") { [weak self] in
            MainActor.assumeIsolated { self?.endLoadingTask() }
        }
    }

    private func endLoadingTask() {
        guard loadingTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(loadingTask)
        loadingTask = .invalid
    }

    private func timeControlChanged() {
        // While another device plays (or the Mix engine does), this player is idle.
        guard !isRemote, !(engineMode && loadedItem == nil) else { return }
        let status = player.timeControlStatus
        var playing = status != .paused
        if status == .paused, wantsToPlay, loadedItem != nil, isNearEnd {
            // Paused by itself at the very end of the song (online streams sometimes do that
            // instead of ending the item): that's the end of the song, go on.
            transientPauseSince = nil
            PlayerDiagnostics.log("pausedAtEnd", ["t": player.currentTime().seconds, "duration": duration])
            finishStuckTrack()
            return
        }
        if status == .paused, wantsToPlay, loadedItem != nil {
            // Not asked for: output reconfiguration. Keep "playing", try to resume.
            playing = true
            handleTransientPause()
        } else {
            transientPauseSince = nil
        }
        // "Waiting" with nothing left to play is the end of the queue, not loading.
        isBuffering = status == .waitingToPlayAtSpecifiedRate && loadedItem != nil
            && player.reasonForWaitingToPlay != .noItemToPlay
        if isBuffering { beginLoadingTask() } else { endLoadingTask() }
        ConnectManager.shared.sendProgress(force: true)
        if playing != isPlaying {
            isPlaying = playing
            if let loadedItem {
                api.reportProgress(loadedItem.trackId, sid: loadedItem.playSessionId, seconds: currentTime, paused: !playing)
            }
        }
        updateNowPlayingPlayback()
    }

    private func tick(_ t: Double) {
        guard t.isFinite, !isScrubbing, Date() > ignoreTicksUntil, pendingSeek == nil, loadedItem != nil else { return }
        currentTime = t
        if let loadedItem, Date().timeIntervalSince(lastProgressReport) > 10, isPlaying {
            lastProgressReport = Date()
            api.reportProgress(loadedItem.trackId, sid: loadedItem.playSessionId, seconds: t, paused: false)
        }
        ConnectManager.shared.sendProgress()
        // Re-sync the lock screen / Dynamic Island position regularly.
        if Date().timeIntervalSince(lastNowPlayingRefresh) > 5 { updateNowPlayingPlayback() }
        if Date().timeIntervalSince(lastTimeSave) > 5 {
            lastTimeSave = Date()
            UserDefaults.standard.set(t, forKey: Self.timeKey)
        }
    }

    private func reportStoppedIfNeeded(finished: Bool = false) {
        guard let loadedItem else { return }
        api.reportStopped(loadedItem.trackId, sid: loadedItem.playSessionId, seconds: finished ? duration : currentTime)
    }

    // MARK: - Lock screen / Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false

        // Shuffle / repeat / favorite buttons on CarPlay's Now Playing screen and the lock screen.
        c.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated {
                guard let self else { return }
                if (e.shuffleType != .off) != self.shuffle { self.toggleShuffle() }
            }
            return .success
        }
        c.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated {
                switch e.repeatType {
                case .one: self?.setRepeat(.one)
                case .all: self?.setRepeat(.all)
                default: self?.setRepeat(.off)
                }
            }
            return .success
        }
        c.likeCommand.localizedTitle = "Favorite"
        c.likeCommand.localizedShortTitle = "Favorite"
        c.likeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let track = self?.current else { return }
                FavoritesStore.shared.toggle(track)
                self?.syncRemoteCommandState()
            }
            return .success
        }
        syncRemoteCommandState()
    }

    /// Mirrors shuffle / repeat / favorite onto the system controls (CarPlay, lock screen).
    func syncRemoteCommandState() {
        let c = MPRemoteCommandCenter.shared()
        c.changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        c.changeRepeatModeCommand.currentRepeatType = switch repeatMode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
        c.likeCommand.isActive = current.map { FavoritesStore.shared.isFavorite($0) } ?? false
    }

    private func updateNowPlayingInfo() {
        NotificationCenter.default.post(name: .musiquePlayerChanged, object: nil)
        syncRemoteCommandState()
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artistLine,
            MPMediaItemPropertyAlbumTitle: t.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: actualRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        if let artwork, artwork.id == t.id {
            info[MPMediaItemPropertyArtwork] = artwork.art
        } else if let url = api.artURL(t, points: 200), let image = ImageCache.shared.cached(url) {
            // Usually already on screen: no wait, the Dynamic Island gets the cover immediately.
            let art = Self.makeArtwork(image)
            artwork = (t.id, art)
            info[MPMediaItemPropertyArtwork] = art
        } else {
            loadArtwork(for: t)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        publishPlaybackState()
    }

    /// 1 only while sound actually comes out: while buffering the lock screen must not keep
    /// advancing (that's what made its progress drift from the real position).
    private var actualRate: Double {
        if isRemote { return isPlaying ? 1 : 0 }
        if engineMode { return isPlaying && !isBuffering ? 1 : 0 }
        return player.timeControlStatus == .playing || (wantsToPlay && transientPauseSince != nil) ? 1 : 0
    }

    private func publishPlaybackState() {
        #if targetEnvironment(macCatalyst)
        // macOS (Control Center, media keys, notch apps) relies on this, iOS ignores it.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing
            : (current == nil ? .stopped : .paused)
        #endif
        NowPlayingExport.shared.publish(track: current, isPlaying: isPlaying,
                                        elapsed: currentTime, duration: duration)
    }

    private func updateNowPlayingPlayback() {
        NotificationCenter.default.post(name: .musiquePlayerChanged, object: nil)
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = actualRate
        info[MPMediaItemPropertyPlaybackDuration] = duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlayingRefresh = Date()
        publishPlaybackState()
    }

    /// Warm the next track's cover in the cache so a skip — including from the lock screen or the
    /// Dynamic Island — shows it at once, with no flash of an empty cover before the real one.
    private func prefetchNextArtwork() {
        guard let i = nextIndex(), queue.indices.contains(i) else { return }
        guard let url = api.artURL(queue[i].track, points: 200), ImageCache.shared.cached(url) == nil else { return }
        Task { _ = await ImageCache.shared.image(for: url) }
    }

    private func loadArtwork(for track: Item) {
        // Already loading this cover: don't restart (repeated updates used to cancel it forever).
        guard artworkLoadingId != track.id else { return }
        artworkTask?.cancel()
        guard let url = api.artURL(track, points: 1000) else { return }
        artworkLoadingId = track.id
        artworkTask = Task { [weak self] in
            defer { if self?.artworkLoadingId == track.id { self?.artworkLoadingId = nil } }
            guard let image = await ImageCache.shared.image(for: url), !Task.isCancelled else { return }
            guard let self, self.current?.id == track.id else { return }
            self.artwork = (track.id, Self.makeArtwork(image))
            self.updateNowPlayingInfo()
        }
    }

    /// Must not be main-actor isolated: MediaPlayer calls the handler on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Persistence (queue survives app restarts)

    private struct Saved: Codable {
        var queue: [QueueEntry]
        var index: Int
        var shuffle: Bool
        var repeatMode: RepeatMode
        var original: [QueueEntry]?
        var source: String?
        var sourceId: String?
        var autoplay: Bool?
    }

    private static let timeKey = "player.time"
    private static var saveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }

    func persist() {
        ConnectManager.shared.stateDidChange()
        UserDefaults.standard.set(currentTime, forKey: Self.timeKey)
        let saved = Saved(queue: queue, index: index, shuffle: shuffle, repeatMode: repeatMode,
                          original: originalOrder, source: sourceName, sourceId: sourceId, autoplay: autoplay)
        // Encoding a long queue + writing it takes a noticeable moment: never on the tap's path.
        let url = Self.saveURL
        Self.saveQueue.async {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Serial: saves are written in order, the last one always wins.
    private static let saveQueue = DispatchQueue(label: "musique.player.save", qos: .utility)

    private func restore() {
        guard let data = try? Data(contentsOf: Self.saveURL),
              let saved = try? JellyfinClient.decoder.decode(Saved.self, from: data),
              saved.queue.indices.contains(saved.index) else { return }
        queue = saved.queue
        index = saved.index
        shuffle = saved.shuffle
        repeatMode = saved.repeatMode
        originalOrder = saved.original
        sourceName = saved.source
        sourceId = saved.sourceId
        autoplay = saved.autoplay ?? false
        currentTime = UserDefaults.standard.double(forKey: Self.timeKey)
        duration = queue[index].track.duration
    }
}


// MARK: - Mix engine glue

extension PlayerManager {
    /// Wires MixEngine's callbacks (called once, from init).
    fileprivate func connectMixEngine() {
        mixEngine.volume = volume
        mixEngine.onTime = { [weak self] t, d in self?.engineTime(t, duration: d) }
        mixEngine.onEntry = { [weak self] id, outgoing in self?.engineEntry(id, outgoing: outgoing) }
        mixEngine.onState = { [weak self] playing, buffering in self?.engineState(playing: playing, buffering: buffering) }
        mixEngine.onProgress = { [weak self] p in
            self?.mixProgress = p
            if p == nil { self?.mixOutgoing = nil }
        }
        mixEngine.onFinished = { [weak self] in self?.engineFinished() }
        mixEngine.onGiveUp = { [weak self] entryId, t, host in
            guard let self else { return }
            self.engineUnavailableUntil = Date().addingTimeInterval(120)
            if let host {
                self.handOverToPlayer((entryId, t, host), fallback: true)
            } else {
                self.mixEngine.stop()
                self.mixProgress = nil
                self.mixOutgoing = nil
                if let i = self.queue.firstIndex(where: { $0.id == entryId }) { self.index = i }
                self.loadCurrent(autoplay: self.wantsToPlay, at: t)
            }
        }
    }

    /// Mix toggled: carry on with the other engine at the same place, without a gap — the new
    /// one gets ready while the old one keeps playing, starts exactly in sync, and they cross in
    /// 0.15 s. (Falls back to a plain restart when that isn't possible.)
    fileprivate func switchEngine() {
        guard !isRemote, current != nil else { return }
        if mixEnabled {
            if isPlaying, let item = loadedItem, let entry = currentEntry, currentTime + 6 < duration {
                handOverToEngine(item: item, entry: entry)
                return
            }
            reportStoppedIfNeeded()
            player.pause()
            player.removeAllItems()
            loadedItem = nil
            loadCurrent(autoplay: isPlaying, at: currentTime)
        } else {
            if isPlaying, mixEngine.active, let point = mixEngine.handoffPoint(minLead: 2.5) {
                handOverToPlayer(point)
                return
            }
            let wasPlaying = isPlaying, t = currentTime
            mixEngine.stop()
            mixProgress = nil
            mixOutgoing = nil
            loadCurrent(autoplay: wasPlaying, at: t)
        }
    }

    /// Mix on, but this song plays plainly (the Pi answered too late for the hand-over): try again
    /// while there's time, further ahead each time. Else the song would end without its transition.
    fileprivate func retryHandOverIfNeeded() {
        guard engineMode, wantsToPlay, !mixEngine.active, !isScrubbing, handOverLead > Self.firstHandOverLead,
              Date() > engineUnavailableUntil, Date() > nextHandOverTry,
              let item = loadedItem, player.currentItem === item, item.status == .readyToPlay,
              player.timeControlStatus == .playing, let entry = currentEntry, item.entryId == entry.id,
              currentTime + handOverLead + 15 < duration else { return }
        handOverToEngine(item: item, entry: entry)
    }

    /// AVQueuePlayer → Mix engine. The engine starts a few seconds ahead, in sync with the player.
    private func handOverToEngine(item: TrackItem, entry: QueueEntry) {
        let at = currentTime + handOverLead
        nextHandOverTry = Date().addingTimeInterval(handOverLead + 5)
        PlayerDiagnostics.log("handoffToEngine", ["from": at, "lead": handOverLead])
        engineStarted(entry, at: at, paused: false)
        mixEngine.start(entryId: entry.id, at: at, autoplay: true, alignTo: { [weak self] t in
            // Host time at which the player will be heard at song time t.
            guard let self, self.loadedItem === item, let timebase = item.timebase,
                  CMTimebaseGetRate(timebase) > 0 else { return nil }
            let host = CMSyncConvertTime(CMTime(seconds: t, preferredTimescale: 44100), from: timebase,
                                         to: CMClockGetHostTimeClock())
            return CMClockConvertHostTimeToSystemUnits(host)
        }, onAligned: { [weak self] host in
            self?.fadeOutPlayer(atHost: host, item: item)
        }, onFailed: { [weak self] unreachable in
            // Not ready in time / Pi unreachable: keep playing plainly (no gap). Only an
            // unreachable Pi keeps the Mix off for a while; one song not ready doesn't.
            guard let self else { return }
            self.mixEngine.stop()
            self.handOverLead = min(self.handOverLead + 3, 12)
            if unreachable { self.engineUnavailableUntil = Date().addingTimeInterval(60) }
            PlayerDiagnostics.log("handoffFailed", ["unreachable": unreachable])
        })
    }

    private func fadeOutPlayer(atHost host: UInt64, item: TrackItem) {
        rampPlayerVolume(to: 0, atHost: host, onlyIf: { [weak self] in self?.loadedItem === item }) { [weak self] in
            guard let self, self.loadedItem === item || self.player.currentItem === item else { return }
            self.api.reportStopped(item.trackId, sid: item.playSessionId, seconds: self.currentTime)
            self.player.pause()
            self.player.removeAllItems()
            self.loadedItem = nil
            self.player.volume = self.volume
            self.endLoadingTask()
        }
    }

    /// Mix engine → AVQueuePlayer, at a point the engine chose (after any transition in progress).
    /// `fallback`: the Pi failed while Mix stays on.
    private func handOverToPlayer(_ point: (UUID, Double, UInt64), fallback: Bool = false) {
        let (entryId, t, host) = point
        guard let entry = queue.first(where: { $0.id == entryId }), let item = makeItem(for: entry) else {
            mixEngine.stop()
            loadCurrent(autoplay: true, at: currentTime)
            return
        }
        PlayerDiagnostics.log("handoffToPlayer", ["from": t])
        reportStoppedIfNeeded()
        player.removeAllItems()
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = false
        player.insert(item, after: nil)
        Task {
            // Ready and positioned before the moment it must be heard.
            let deadline = host > mach_absolute_time() ? AVAudioTime.seconds(forHostTime: host - mach_absolute_time()) : 0
            let started = Date()
            while item.status != .readyToPlay, Date().timeIntervalSince(started) < deadline - 0.3 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let seeked = await item.seek(to: CMTime(seconds: t, preferredTimescale: 44100), toleranceBefore: .zero,
                                         toleranceAfter: .zero)
            let latency = AVAudioSession.sharedInstance().outputLatency + AVAudioSession.sharedInstance().ioBufferDuration
            guard item.status == .readyToPlay, seeked, !mixEnabled || fallback,
                  host > mach_absolute_time() + AVAudioTime.hostTime(forSeconds: latency + 0.05) else {
                // Not ready in time: plain switch.
                player.automaticallyWaitsToMinimizeStalling = true
                player.volume = volume
                if loadedItem == nil { player.removeAllItems() }  // the engine plays on: nothing stays loaded
                if !mixEnabled || fallback {
                    mixEngine.stop()
                    if let i = queue.firstIndex(of: entry) { index = i }
                    loadCurrent(autoplay: true, at: fallback ? t : currentTime)
                }
                return
            }
            if let i = queue.firstIndex(of: entry) { index = i }
            loadedItem = item
            observeStatus(of: item)
            duration = entry.track.duration
            wantsToPlay = true
            // Heard at `host` = rendered `latency` earlier.
            player.setRate(1, time: CMTime(seconds: t, preferredTimescale: 44100),
                           atHostTime: CMClockMakeHostTimeFromSystemUnits(host - AVAudioTime.hostTime(forSeconds: latency)))
            rampPlayerVolume(to: volume, atHost: host, onlyIf: { [weak self] in self?.loadedItem === item }) { [weak self] in
                self?.player.automaticallyWaitsToMinimizeStalling = true
            }
            mixEngine.fadeOutAndStop(atHost: host)
            mixProgress = nil
            mixOutgoing = nil
            api.reportStart(entry.track.id, sid: item.playSessionId, seconds: t, paused: false)
            refreshNextItem()
            updateNowPlayingInfo()
        }
    }

    /// `onlyIf`: checked until the end — the fade is for one song; if another one is playing by
    /// then (skip…), it's dropped (else that song plays on silent). A newer fade replaces it too.
    private func rampPlayerVolume(to target: Float, atHost host: UInt64, onlyIf still: @escaping () -> Bool,
                                  then done: @escaping () -> Void) {
        let now = mach_absolute_time()
        let delay = host > now ? AVAudioTime.seconds(forHostTime: host - now) : 0
        let id = UUID()
        playerRamp = id
        Task {
            try? await Task.sleep(for: .seconds(delay))
            let from = player.volume
            for step in 1...15 {
                guard playerRamp == id, still() else {
                    if playerRamp == id { playerRamp = nil }
                    return
                }
                let p = Float(step) / 15
                player.volume = target > from ? target * sin(p * .pi / 2) : from * cos(p * .pi / 2)
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard playerRamp == id, still() else {
                if playerRamp == id { playerRamp = nil }
                return
            }
            player.volume = target
            playerRamp = nil
            done()
        }
    }

    fileprivate func engineStarted(_ entry: QueueEntry, at time: Double, paused: Bool) {
        engineSession = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        api.reportStart(entry.track.id, sid: engineSession, seconds: time, paused: paused)
    }

    private func engineTime(_ t: Double, duration d: Double) {
        guard !isScrubbing else { return }
        currentTime = t
        if let track = current, track.duration > 0 { duration = track.duration } else if d > 0 { duration = d }
        if Date().timeIntervalSince(lastProgressReport) > 10, isPlaying, let track = current {
            lastProgressReport = Date()
            api.reportProgress(track.id, sid: engineSession, seconds: t, paused: false)
        }
        ConnectManager.shared.sendProgress()
        if Date().timeIntervalSince(lastNowPlayingRefresh) > 5 { updateNowPlayingPlayback() }
        if Date().timeIntervalSince(lastTimeSave) > 5 {
            lastTimeSave = Date()
            UserDefaults.standard.set(t, forKey: Self.timeKey)
        }
    }

    /// The engine moved on to the next song (in the middle of a transition, or a plain start).
    private func engineEntry(_ id: UUID, outgoing: Item?) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        if let previous = current {
            api.reportStopped(previous.id, sid: engineSession, seconds: duration)
            OfflineStore.shared.listenedToEnd(previous)
        }
        index = i
        mixOutgoing = outgoing
        let track = queue[i].track
        duration = track.duration
        engineStarted(queue[i], at: 0, paused: false)
        ListeningHistory.shared.record(track)
        if let outgoing { PlayerDiagnostics.log("mixPlaying", ["from": outgoing.title]) }
        updateNowPlayingInfo()
        prefetchNextArtwork()
        queueDidChange()
        persist()
    }

    private func engineState(playing: Bool, buffering: Bool) {
        isBuffering = buffering
        if buffering { beginLoadingTask() } else { endLoadingTask() }
        if playing != isPlaying { isPlaying = playing }
        updateNowPlayingPlayback()
        ConnectManager.shared.sendProgress(force: true)
    }

    private func engineFinished() {
        wantsToPlay = false
        isPlaying = false
        isBuffering = false
        endLoadingTask()
        if let track = current {
            api.reportStopped(track.id, sid: engineSession, seconds: duration)
            OfflineStore.shared.listenedToEnd(track)
        }
        currentTime = 0
        mixProgress = nil
        mixOutgoing = nil
        updateNowPlayingPlayback()
        persist()
        ToastCenter.shared.show("End of the queue", systemImage: "stop.circle")
    }
}
