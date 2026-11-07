import AVFoundation
import Foundation

/// Mix mode playback: the Pi renders each song as gapless *pieces* (the song, with the DJ
/// transition from the previous one at its start; see backend/api/automix.py), and this engine
/// schedules them back to back on ONE AVAudioPlayerNode. AVAudioPlayerNode plays scheduled audio
/// sample-continuously, so the joins — including the transitions — have no gap at all (an
/// AVQueuePlayer switching items mid-music always leaves a small one).
///
/// PlayerManager stays the source of truth for the queue and drives this engine when Mix is on;
/// the engine reports the song time, song changes and its state back through the callbacks.
@MainActor
final class MixEngine {
    static let shared = MixEngine()

    // Callbacks (main actor).
    var onTime: ((_ songTime: Double, _ duration: Double) -> Void)?
    var onEntry: ((_ entryId: UUID, _ outgoing: Item?) -> Void)?
    var onState: ((_ playing: Bool, _ buffering: Bool) -> Void)?
    var onProgress: ((_ transition: Double?) -> Void)?
    var onFinished: (() -> Void)?
    /// The Pi can't render what follows: (entry, song time, host time to take over at, or nil = now).
    var onGiveUp: ((UUID, Double, UInt64?) -> Void)?

    private(set) var active = false
    var volume: Float = 1 { didSet { engine.mainMixerNode.outputVolume = volume } }

    private struct Spec {
        var entryId: UUID
        var prevId: UUID?
        var start: Double
        var until: Double?
        var nextId: UUID?
    }

    private struct Piece {
        let entryId: UUID
        let file: AVAudioFile
        let frames: AVAudioFramePosition
        let timelineStart: AVAudioFramePosition  // player-timeline sample of its first frame
        let xStart: Double          // song time = piece time − xStart
        let outgoingUntil: Double   // piece time until which the previous song is still heard
        let outgoing: Item?
        let endsAt: Double          // song time at the end of the piece
        let cut: Double             // song time where it hands over to the next song
        let duration: Double
        let plannedNextId: UUID?
        /// The previous song's time and duration when this piece starts (it is still heard first).
        var outgoingFrom: Double = 0
        var outgoingDuration: Double = 0
        var specKey = ""
    }

    private struct SegmentInfo: Decodable {
        var ok: Bool
        var reason: String?
        var id: String?
        var url: String?
        var xStart: Double?
        var outgoingUntil: Double?
        var endsAt: Double?
        var cut: Double?
        var duration: Double?
    }

    enum Failure: Error { case unavailable(String), noFile }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private let sampleRate = 44100.0
    /// Scheduled on the node (can't be taken back), then downloaded but not scheduled yet: pieces
    /// are only handed to the node ~8 s before they play, so a queue change can still drop them.
    private var pieces: [Piece] = []
    private var ready: [Piece] = []
    private var scheduledEnd: AVAudioFramePosition = 0
    private var requesting = false
    private var requestStarted = Date.distantPast
    /// Failed requests in a row, and no new try before `retryAfter` (never hammer the Pi).
    private var failures = 0
    private var retryAfter = Date.distantPast
    private var generation = 0  // bumped on every restart: late downloads are dropped
    private var requestGen = 0  // bumped when queued-but-unscheduled pieces are dropped
    private static let scheduleLead = 8.0
    /// Seamless switch from AVQueuePlayer: when the first piece is ready, start in sync with it.
    private var alignTo: ((Double) -> UInt64?)?
    private var alignTime: Double = 0
    private var onAligned: ((UInt64) -> Void)?
    /// The take-over didn't happen; true when the Pi couldn't be reached (not just this song).
    private var onAlignFailed: ((_ piUnreachable: Bool) -> Void)?
    private var ramp: Timer?
    /// A fade is scheduled or running: the output volume is deliberately off the app volume.
    private var fading = false
    private var timer: Timer?
    private var wantsToPlay = false
    private var currentEntryId: UUID?
    private var lastSongTime: Double = 0
    private var lastState: (Bool, Bool)?
    private var stalledSince: Date?

    private init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.visualizerTap())
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        Self.cleanCache()
    }

    // MARK: - Control

    /// Plays `entryId` from `time` (no transition into it: a fresh start, after a tap / seek / skip).
    func start(entryId: UUID, at time: Double, autoplay: Bool) {
        start(entryId: entryId, at: time, autoplay: autoplay, alignTo: nil, onAligned: nil, onFailed: nil)
    }

    /// `alignTo`: host time at which the song reaches a given time in the other player (it keeps
    /// playing meanwhile); the engine then starts exactly there, fading in, and `onAligned` gets
    /// that host time so the other player fades out.
    func start(entryId: UUID, at time: Double, autoplay: Bool, alignTo: ((Double) -> UInt64?)?,
               onAligned: ((UInt64) -> Void)?, onFailed: ((_ piUnreachable: Bool) -> Void)?) {
        PlayerDiagnostics.log("mixStart", ["entry": title(entryId), "from": time, "aligned": alignTo != nil])
        resetPlayback()
        active = true
        wantsToPlay = autoplay
        currentEntryId = entryId
        lastSongTime = time
        self.alignTo = alignTo
        alignTime = time
        self.onAligned = onAligned
        onAlignFailed = onFailed
        if alignTo == nil { report(playing: autoplay, buffering: true) }
        startEngine()
        request(Spec(entryId: entryId, prevId: nil, start: time, until: time + 20,
                     nextId: transitionTarget(after: entryId)?.id))
        startTimer()
    }

    func play() {
        guard active else { return }
        wantsToPlay = true
        if scheduledEnd > 0 { playNode() } else { startEngine() }
        report(playing: true, buffering: scheduledEnd == 0)
    }

    func pause() {
        wantsToPlay = false
        node.pause()
        engine.pause()
        report(playing: false, buffering: false)
    }

    func stop() {
        resetPlayback()
        active = false
        wantsToPlay = false
        timer?.invalidate()
        timer = nil
        engine.pause()
        onProgress?(nil)
    }

    func seek(to time: Double) {
        guard active, let entry = currentEntryId else { return }
        start(entryId: entry, at: max(0, time), autoplay: wantsToPlay)
    }

    /// The queue changed: pieces downloaded but not scheduled yet (and any on the way) may lead to
    /// the old next song: drop them and ask again — nothing that plays is touched, no gap. What is
    /// already scheduled (the next ~8 s, or a transition already going) plays as planned.
    func queueChanged() {
        guard active else { return }
        PlayerDiagnostics.log("mixQueueChanged", ["dropped": ready.count, "inFlight": requesting])
        requestGen += 1
        requesting = false
        lastRequested = nil
        ready = []
        tick()
    }

    // MARK: - Pieces

    private func request(_ spec: Spec) {
        // A request stuck for 45 s (network): forget it, ask again.
        guard !requesting || Date().timeIntervalSince(requestStarted) > 45, Date() >= retryAfter else { return }
        requesting = true
        requestStarted = Date()
        let gen = generation, rgen = requestGen
        PlayerDiagnostics.log("mixRequest", ["prev": spec.prevId != nil, "start": spec.start,
                                             "until": spec.until ?? -1, "entry": title(spec.entryId)])
        Task {
            do {
                var piece = try await fetch(spec)
                guard gen == generation, rgen == requestGen else { return }
                requesting = false
                failures = 0
                piece.specKey = "\(spec.entryId)|\(spec.start)|\(spec.prevId?.uuidString ?? "")"
                // A retried request whose first try came back too: keep it once.
                guard !(pieces + ready).contains(where: { $0.specKey == piece.specKey }) else { return }
                ready.append(piece)
                tick()
            } catch {
                guard gen == generation, rgen == requestGen else { return }
                requesting = false
                failures += 1
                PlayerDiagnostics.log("mixPieceFailed", ["error": "\(error)", "failures": failures])
                if alignTo != nil {
                    // Taking over from the plain player: it just keeps playing.
                    alignTo = nil
                    onAlignFailed?(!(error is Failure))
                    return
                }
                // One more try a second later; after that, the plain player carries on with the
                // song (it streams it straight from Jellyfin) instead of waiting on the Pi.
                retryAfter = Date().addingTimeInterval(1)
                if failures >= 2 { giveUp(spec) }
            }
        }
    }

    private func title(_ id: UUID?) -> String {
        guard let id else { return "" }
        return PlayerManager.shared.queue.first { $0.id == id }?.track.title ?? "?"
    }

    private func key(_ id: UUID?) -> String? {
        guard let id, let entry = PlayerManager.shared.queue.first(where: { $0.id == id }) else { return nil }
        return entry.track.externalKey ?? entry.track.id
    }

    private func fetch(_ spec: Spec) async throws -> Piece {
        guard let songKey = key(spec.entryId) else { throw Failure.unavailable("son retiré de la file") }
        var query = ["key": songKey, "start": String(spec.start)]
        if let prev = key(spec.prevId) { query["prev"] = prev }
        if let next = key(spec.nextId) { query["next"] = next }
        if let until = spec.until { query["until"] = String(until) }
        let info: SegmentInfo = try await SonalexAPI.shared.mixSegment(query)
        guard info.ok, let id = info.id, let path = info.url, let url = SonalexAPI.shared.mixStreamURL(path) else {
            throw Failure.unavailable(info.reason ?? "?")
        }
        let local = Self.cacheDir.appendingPathComponent("\(id).m4a")
        var xStart = info.xStart ?? 0
        var outgoingUntil = info.outgoingUntil ?? 0
        if FileManager.default.fileExists(atPath: local.path),
           let meta = UserDefaults.standard.dictionary(forKey: "mix.meta.\(id)") as? [String: Double] {
            xStart = meta["xStart"] ?? xStart
            outgoingUntil = meta["outgoingUntil"] ?? outgoingUntil
        } else {
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.noFile }
            // The song's real start in the piece, measured by the Pi when it aligned the beats.
            let headers = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
            func header(_ name: String) -> Double? {
                headers.first { ($0.key as? String)?.lowercased() == name.lowercased() }
                    .flatMap { ($0.value as? String).flatMap(Double.init) }
            }
            xStart = header("X-Segment-xStart") ?? xStart
            outgoingUntil = header("X-Segment-outgoingUntil") ?? outgoingUntil
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: tmp, to: local)
            UserDefaults.standard.set(["xStart": xStart, "outgoingUntil": outgoingUntil], forKey: "mix.meta.\(id)")
        }
        let file = try AVAudioFile(forReading: local)
        let outgoing = spec.prevId.flatMap { id in PlayerManager.shared.queue.first { $0.id == id }?.track }
        return Piece(entryId: spec.entryId, file: file, frames: file.length, timelineStart: 0,
                     xStart: xStart, outgoingUntil: spec.prevId == nil ? 0 : outgoingUntil, outgoing: outgoing,
                     endsAt: info.endsAt ?? 0, cut: info.cut ?? info.duration ?? 0, duration: info.duration ?? 0,
                     plannedNextId: spec.nextId)
    }

    private func schedule(_ incoming: Piece) {
        var piece = Piece(entryId: incoming.entryId, file: incoming.file, frames: incoming.frames,
                          timelineStart: scheduledEnd, xStart: incoming.xStart, outgoingUntil: incoming.outgoingUntil,
                          outgoing: incoming.outgoing, endsAt: incoming.endsAt, cut: incoming.cut,
                          duration: incoming.duration, plannedNextId: incoming.plannedNextId)
        piece.specKey = incoming.specKey
        if let before = pieces.last, before.entryId != piece.entryId {
            piece.outgoingFrom = before.endsAt
            piece.outgoingDuration = before.duration
        }
        node.scheduleSegment(piece.file, startingFrame: 0, frameCount: AVAudioFrameCount(piece.frames), at: nil)
        scheduledEnd += piece.frames
        pieces.append(piece)
        guard wantsToPlay, !node.isPlaying else { return }
        guard startEngine() else {
            if alignTo != nil {
                alignTo = nil
                onAlignFailed?(false)
            } else {
                retryPlay()
            }
            return
        }
        if let alignTo {
            // Start in sync with the other player: at the host time it plays `alignTime`, minus the
            // output latency (that host time is when it is *heard*).
            self.alignTo = nil
            let latency = AVAudioSession.sharedInstance().outputLatency + AVAudioSession.sharedInstance().ioBufferDuration
            guard let heard = alignTo(alignTime),
                  heard > mach_absolute_time() + AVAudioTime.hostTime(forSeconds: latency + 0.05) else {
                PlayerDiagnostics.log("mixAlignMissed", [:])
                onAlignFailed?(false)
                return
            }
            let renderAt = heard - AVAudioTime.hostTime(forSeconds: latency)
            engine.mainMixerNode.outputVolume = 0
            node.play(at: AVAudioTime(hostTime: renderAt))
            fade(to: volume, atHost: heard, duration: 0.15)
            onAligned?(heard)
            report(playing: true, buffering: false)
        } else {
            node.play()
        }
    }

    /// Next ~8 s: hand the next downloaded piece to the node.
    private func scheduleReady(raw: AVAudioFramePosition?) {
        guard let next = ready.first else { return }
        let left = raw.map { Double(scheduledEnd - $0) / sampleRate } ?? 0
        guard pieces.isEmpty || left < Self.scheduleLead else { return }
        ready.removeFirst()
        schedule(next)
    }

    /// What to fetch after the last scheduled piece.
    private var lastRequested: (UUID, Double, UUID?)?

    private func following(_ last: Piece) -> Spec? {
        guard let spec = followingSpec(last) else { return nil }
        // Already asked for exactly this one and it's on its way.
        if requesting, let r = lastRequested, r.0 == spec.entryId, r.1 == spec.start, r.2 == spec.prevId { return spec }
        lastRequested = (spec.entryId, spec.start, spec.prevId)
        return spec
    }

    private func followingSpec(_ last: Piece) -> Spec? {
        let manager = PlayerManager.shared
        if last.endsAt < last.cut - 0.01 {
            // More of the same song (the Pi recomputes the cut if the next song changed).
            return Spec(entryId: last.entryId, prevId: nil, start: last.endsAt, until: last.endsAt + 60,
                        nextId: transitionTarget(after: last.entryId)?.id)
        }
        let target = transitionTarget(after: last.entryId)
        if last.cut < last.duration - 0.05 {  // this piece ends on a planned transition
            if let target, target.id == last.plannedNextId {
                return Spec(entryId: target.id, prevId: last.entryId, start: 0, until: 60,
                            nextId: transitionTarget(after: target.id)?.id)
            }
            // The next song changed after the cut was planned: the rest of this song, then a plain start.
            return Spec(entryId: last.entryId, prevId: nil, start: last.endsAt, until: nil, nextId: nil)
        }
        if manager.repeatMode == .one {
            return Spec(entryId: last.entryId, prevId: nil, start: 0, until: 20, nextId: nil)
        }
        guard let target else { return nil }
        return Spec(entryId: target.id, prevId: nil, start: 0, until: 20, nextId: transitionTarget(after: target.id)?.id)
    }

    /// The song a transition goes to (none with repeat-one or at the end of the queue).
    private func transitionTarget(after id: UUID) -> QueueEntry? {
        let manager = PlayerManager.shared
        guard manager.repeatMode != .one, let i = manager.queue.firstIndex(where: { $0.id == id }) else { return nil }
        if i + 1 < manager.queue.count { return manager.queue[i + 1] }
        return manager.repeatMode == .all ? manager.queue.first : nil
    }

    /// The Pi can't make what comes next: hand the song over to the plain player, before the
    /// music runs out if possible (in sync, no gap), else right where it stopped.
    private func giveUp(_ spec: Spec) {
        guard let onGiveUp else { failed(spec); return }
        PlayerDiagnostics.log("mixGiveUp", ["entry": title(spec.entryId)])
        let point = handoffPoint(minLead: 1.5)
        let entry = point?.0 ?? currentEntryId ?? spec.entryId
        let time = point?.1 ?? (entry == spec.entryId && pieces.isEmpty ? spec.start : lastSongTime)
        failures = 0
        retryAfter = Date().addingTimeInterval(30)
        onGiveUp(entry, time, point?.2)
    }

    private func failed(_ spec: Spec) {
        // The Pi couldn't make it (song not available…): skip to the following one, or stop.
        guard let next = transitionTarget(after: spec.entryId), next.id != spec.entryId else {
            if pieces.isEmpty { finish() }
            return
        }
        if pieces.isEmpty {
            start(entryId: next.id, at: 0, autoplay: wantsToPlay)
        }
    }

    // MARK: - Clock

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func position() -> AVAudioFramePosition? {
        guard let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let t = node.playerTime(forNodeTime: nodeTime) else { return nil }
        return t.sampleTime
    }

    private func tick() {
        guard active else { return }
        guard let raw = position() else {  // paused / not started: nothing moves
            if pieces.isEmpty { scheduleReady(raw: nil) }
            return
        }
        // The audio clock keeps running when nothing is scheduled (network too slow): never count
        // that as playing further into the song.
        let pos = min(raw, max(0, scheduledEnd - 1))
        guard let i = pieces.lastIndex(where: { $0.timelineStart <= pos }) else { return }
        if i > 0 { pieces.removeFirst(i) }
        let piece = pieces[0]
        let pieceTime = Double(pos - piece.timelineStart) / sampleRate
        let songTime = max(0, pieceTime - piece.xStart)

        if piece.entryId != currentEntryId, pieceTime >= max(0, piece.xStart) || piece.outgoing == nil {
            currentEntryId = piece.entryId
            PlayerDiagnostics.log("mixEntry", ["entry": title(piece.entryId), "transition": piece.outgoing != nil])
            onEntry?(piece.entryId, piece.outgoing)
        }
        if piece.entryId != currentEntryId {
            // The new song hasn't come in yet: the previous one goes on (gliding into it).
            onTime?(min(piece.outgoingFrom + pieceTime, piece.outgoingDuration), piece.outgoingDuration)
            onProgress?(nil)
        } else {
            lastSongTime = songTime
            onTime?(songTime, piece.duration)
            // Both songs heard: from the new one's first sample to the end of the old one.
            let span = piece.outgoingUntil - max(0, piece.xStart)
            if piece.outgoing != nil, span > 0.5, pieceTime < piece.outgoingUntil {
                onProgress?(min(1, max(0, (pieceTime - max(0, piece.xStart)) / span)))
            } else {
                onProgress?(nil)
            }
        }

        scheduleReady(raw: raw)
        // Keep ~45 s downloaded ahead: fetch what follows the last piece (scheduled or waiting).
        let remaining = Double(scheduledEnd - raw) / sampleRate + ready.reduce(0) { $0 + Double($1.frames) / sampleRate }
        if remaining < 45, let last = ready.last ?? pieces.last {
            if let spec = following(last) {
                if !requesting || Date().timeIntervalSince(requestStarted) > 45 { request(spec) }
            } else if remaining <= 0.02, !requesting, ready.isEmpty {
                finish()
                return
            }
        }
        // Ran out before the next piece arrived (slow network): buffering.
        let starving = wantsToPlay && raw >= scheduledEnd - 1
        if starving, stalledSince == nil {
            stalledSince = Date()
            PlayerDiagnostics.log("mixStarving", ["entry": title(piece.entryId), "song": songTime])
        } else if !starving {
            stalledSince = nil
        }
        report(playing: wantsToPlay, buffering: starving)
    }

    private func finish() {
        stop()
        onFinished?()
    }

    private func report(playing: Bool, buffering: Bool) {
        guard lastState.map({ $0 != (playing, buffering) }) ?? true else { return }
        lastState = (playing, buffering)
        onState?(playing, buffering)
    }

    // MARK: - Handing over to the other player

    /// Where the other player can take over smoothly: ≥ `minLead` s ahead, outside any transition,
    /// in what is already downloaded. (entry, song time there, host time it will be heard.)
    func handoffPoint(minLead: Double) -> (UUID, Double, UInt64)? {
        guard active, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid, nodeTime.isHostTimeValid,
              let now = node.playerTime(forNodeTime: nodeTime) else { return nil }
        var start = pieces.first?.timelineStart ?? 0
        for piece in pieces + ready {
            let pieceStart = pieces.contains(where: { $0.specKey == piece.specKey }) ? piece.timelineStart : start
            start = pieceStart + piece.frames
            let notBefore = Double(now.sampleTime - pieceStart) / sampleRate + minLead
            let afterBlend = piece.outgoing != nil ? piece.outgoingUntil + 0.5 : 0
            let at = max(notBefore, afterBlend, max(0, piece.xStart))
            guard at < Double(piece.frames) / sampleRate - 1 else { continue }
            let sample = pieceStart + AVAudioFramePosition(at * sampleRate)
            let latency = AVAudioSession.sharedInstance().outputLatency + AVAudioSession.sharedInstance().ioBufferDuration
            let host = nodeTime.hostTime + AVAudioTime.hostTime(forSeconds: Double(sample - now.sampleTime) / sampleRate + latency)
            return (piece.entryId, at - piece.xStart, host)
        }
        return nil
    }

    /// Fades out when the other player comes in (host time it is heard), then stops.
    func fadeOutAndStop(atHost host: UInt64) {
        fade(to: 0, atHost: host, duration: 0.15) { [weak self] in self?.stop() }
    }

    private func fade(to target: Float, atHost host: UInt64, duration: Double, then done: (() -> Void)? = nil) {
        ramp?.invalidate()
        fading = true
        let now = mach_absolute_time()
        let delay = host > now ? AVAudioTime.seconds(forHostTime: host - now) : 0
        let mixer = engine.mainMixerNode
        // A fade planned for what played before a restart (skip, new song…) must not touch what
        // plays now: a late fade-out once left the next song silent, or stopped it.
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.ramp?.invalidate()
                let from = mixer.outputVolume
                let began = Date()
                self.ramp = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        let p = Float(min(1, Date().timeIntervalSince(began) / duration))
                        // Equal power: the two players hold the same music at the same place.
                        mixer.outputVolume = target > from ? target * sin(p * .pi / 2) : from * cos(p * .pi / 2)
                        if p >= 1 {
                            timer.invalidate()
                            self.fading = false
                            done?()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Engine

    /// AVAudioPlayerNode.play() while the engine isn't running raises an exception: the app dies
    /// on the spot. So the node is only ever played after this returned true.
    @discardableResult
    private func startEngine() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            // Right after launch (or after a while in the background) the audio session may not be
            // active yet — PlayerManager activates it off the main thread: do it now, try again.
            try? AVAudioSession.sharedInstance().setActive(true)
            do {
                try engine.start()
                return true
            } catch {
                PlayerDiagnostics.log("mixEngineStart", ["error": "\(error)"])
                return false
            }
        }
    }

    private func playNode() {
        if startEngine() { node.play() } else { retryPlay() }
    }

    /// The engine wouldn't start: try again every half second (PlayerManager's watchdog switches
    /// to the plain player if it never does). A restart or a stop ends it (generation).
    private func retryPlay() {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.active, self.wantsToPlay,
                      self.scheduledEnd > 0, !self.node.isPlaying else { return }
                self.playNode()
            }
        }
    }

    private func resetPlayback() {
        generation += 1
        requesting = false
        requestGen += 1
        failures = 0
        retryAfter = .distantPast
        node.stop()
        pieces = []
        ready = []
        scheduledEnd = 0
        lastState = nil
        ramp?.invalidate()
        fading = false
        alignTo = nil
        onAligned = nil
        onAlignFailed = nil
        engine.mainMixerNode.outputVolume = volume
    }

    // MARK: - Watchdog support (PlayerManager.checkPlayback)

    /// How far the audio has really been played (s): stops moving when nothing is rendering or
    /// the scheduled audio ran out. nil when not started / paused.
    var playedSeconds: Double? {
        guard active, let raw = position() else { return nil }
        return Double(min(raw, scheduledEnd)) / sampleRate
    }

    /// Outside a fade, the output is at the app volume: whatever cut a fade short never leaves
    /// the music silent.
    func repairVolumeIfNeeded() {
        let mixer = engine.mainMixerNode
        guard active, !fading, abs(mixer.outputVolume - volume) > 0.01 else { return }
        PlayerDiagnostics.log("mixVolumeRepaired", ["was": mixer.outputVolume])
        mixer.outputVolume = volume
    }

    /// Output changed (headphones, AirPlay…): the engine stops itself; carry on from here.
    private func configurationChanged() {
        guard active, let entry = currentEntryId else { return }
        PlayerDiagnostics.log("mixConfigChange", ["song": lastSongTime])
        start(entryId: entry, at: lastSongTime, autoplay: wantsToPlay)
    }

    // MARK: - Visualizer

    /// Built outside the main actor: the tap runs on the audio thread.
    private nonisolated static func visualizerTap() -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0, channels > 0 else { return }
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<channels {
                let samples = data[c]
                for f in 0..<frames { mono[f] += samples[f] }
            }
            let scale = 1 / Float(channels)
            for f in 0..<frames { mono[f] *= scale }
            mono.withUnsafeBufferPointer { AmbilightAudioSink.shared.push($0, sampleRate: buffer.format.sampleRate) }
        }
    }

    // MARK: - Cache

    private static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mix", isDirectory: true)

    /// Keeps the most recent pieces only (~1 GB at most).
    private static func cleanCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        var total = 0
        for url in sorted {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if total > 1 << 30 {
                try? fm.removeItem(at: url)
                UserDefaults.standard.removeObject(forKey: "mix.meta.\(url.deletingPathExtension().lastPathComponent)")
            }
        }
    }
}
