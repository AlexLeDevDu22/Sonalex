import Foundation
import Network
import Observation
import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted by PlayerManager when the track or play/pause state changes.
    static let musiquePlayerChanged = Notification.Name("musiquePlayerChanged")
}

enum AmbiError: LocalizedError {
    case notConnected, unauthorized
    case server(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Mac introuvable."
        case .unauthorized: "Ce Mac ne reconnaît plus l’iPhone. Refais l’appairage."
        case .server(_, let message): message ?? "Erreur du Mac."
        }
    }
}

/// Talks to the Ambilight server running on the Mac (LED strip + mouse lighting).
@Observable
@MainActor
final class AmbilightClient {
    static let shared = AmbilightClient()

    enum Connection: Equatable { case searching, online, reconnecting, offline }

    // MARK: State

    private(set) var base: String?
    private(set) var token: String?
    private(set) var info: AmbiInfo?
    /// The Mac answers on the network right now (drives the visibility of the feature).
    private(set) var reachable = false
    private(set) var connection: Connection = .searching
    private(set) var catalog: AmbiCatalog?
    private(set) var config: AmbiConfig?
    private(set) var live: AmbiLive?
    private(set) var discovered: [AmbilightDiscovery.Found] = []
    private(set) var remoteBanner: String?
    private(set) var musicMode: Bool
    private(set) var pairingId: String?

    var isPaired: Bool { token != nil && (info?.paired ?? true) }
    var macName: String { info?.computer ?? "Mac" }
    var isOn: Bool { live?.leds?.running == true || live?.mouse?.running == true }
    /// What the bulb in Now Playing and the "Lumières sur la musique" switch show: both are the
    /// same thing — lights on *and* following the app's music.
    var musicActive: Bool { musicMode && isOn }

    // MARK: Private

    @ObservationIgnored private let discovery = AmbilightDiscovery()
    @ObservationIgnored private let streamer = AmbilightAudioStreamer()
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var eventsViewers = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastCfg: Int?
    @ObservationIgnored private var lastRemoteId: Int?
    @ObservationIgnored private var reportedTrackId: String?
    @ObservationIgnored private var reportedPlaying: Bool?
    @ObservationIgnored private var throttles: [String: (last: Date, pending: [String: Any]?, task: Task<Void, Never>?)] = [:]
    @ObservationIgnored private var started = false
    /// After a power command, the live feed may still carry the old state for a moment:
    /// keep showing what was asked until it catches up (this was the toggle flicker).
    @ObservationIgnored private var ledsOverride: (on: Bool, until: Date)?
    @ObservationIgnored private var mouseOverride: (on: Bool, until: Date)?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPath: String?

    private static let musicKey = "ambi.musicMode"
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private init() {
        musicMode = UserDefaults.standard.bool(forKey: Self.musicKey)
        base = Keychain.get("host")
        token = Keychain.get("token")
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        discovery.onChange = { [weak self] found in
            guard let self else { return }
            self.discovered = found
            if !self.reachable { Task { await self.adoptDiscoveredIfNeeded() } }
        }
        discovery.start()
        NotificationCenter.default.addObserver(forName: .musiquePlayerChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playerChanged() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.networkMayHaveChanged() }
        }
        // Coming home: as soon as Wi-Fi is back, look for the Mac again (cheap, event-driven).
        pathMonitor.pathUpdateHandler = Self.pathChanged
        pathMonitor.start(queue: DispatchQueue(label: "ambilight.path"))
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probe()
                let wait: Double = (self?.reachable ?? false) ? 20 : 8
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    nonisolated private static func pathChanged(_ path: NWPath) {
        let signature = "\(path.status)|\(path.usesInterfaceType(.wifi))|\(path.availableInterfaces.map(\.name))"
        Task { @MainActor in
            let client = AmbilightClient.shared
            guard client.lastPath != signature else { return }
            client.lastPath = signature
            client.networkMayHaveChanged()
        }
    }

    /// Network changed or app came back: restart Bonjour and probe now, then again shortly after
    /// (Wi-Fi often needs a second to get its address).
    private func networkMayHaveChanged() {
        guard started else { return }
        discovery.restart()
        failures = 0
        Task {
            await probe()
            try? await Task.sleep(for: .seconds(2))
            if !reachable { await probe() }
        }
    }

    func retry() {
        connection = .searching
        if !discovery.isRunning { discovery.start() }
        Task { await probe() }
    }

    private func probe() async {
        if !discovery.isRunning { discovery.start() }
        guard let base else {
            connection = discovered.isEmpty ? .offline : .searching
            await adoptDiscoveredIfNeeded()
            return
        }
        if let i = try? await fetchInfo(base) {
            info = i
            failures = 0
            reachable = true
            if token != nil, i.paired == false {
                // Token revoked on the Mac.
                forgetToken()
            }
            if connection != .reconnecting || eventsTask == nil { connection = .online }
            // Without the live feed (page not on screen), refresh the on/off state from time to time
            // so the bulb in Now Playing stays right.
            if isPaired, catalog == nil || eventsTask == nil { await reloadState() }
            reconcile()
        } else {
            failures += 1
            if failures >= 2 {
                reachable = false
                connection = .offline
                reconcile()
            }
            await adoptDiscoveredIfNeeded()
        }
    }

    /// When the saved Mac doesn't answer (or there is none), try the ones Bonjour sees.
    private func adoptDiscoveredIfNeeded() async {
        guard !reachable, !discovered.isEmpty else { return }
        let savedName = Keychain.get("name")
        let candidates = discovered.filter { $0.name == savedName } + discovered.filter { $0.name != savedName }
        for found in candidates {
            guard let url = await AmbilightDiscovery.resolve(found.endpoint),
                  let i = try? await fetchInfo(url) else { continue }
            setBase(url, name: found.name)
            info = i
            failures = 0
            reachable = true
            connection = .online
            if isPaired { await reloadState() }
            reconcile()
            return
        }
    }

    private func setBase(_ url: String, name: String? = nil) {
        if url != base {
            base = url
            Keychain.set(url, for: "host")
        }
        if let name { Keychain.set(name, for: "name") }
    }

    /// Manual fallback: "192.168.1.25:8787".
    func connectManually(_ address: String) async -> Bool {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.dropFirst(7).contains(":") { s += ":8787" }
        guard let i = try? await fetchInfo(s) else { return false }
        setBase(s)
        info = i
        reachable = true
        connection = .online
        if isPaired { await reloadState() }
        return true
    }

    func connect(to found: AmbilightDiscovery.Found) async -> Bool {
        guard let url = await AmbilightDiscovery.resolve(found.endpoint),
              let i = try? await fetchInfo(url) else { return false }
        if url != base { forgetToken() }
        setBase(url, name: found.name)
        info = i
        reachable = true
        connection = .online
        return true
    }

    /// "Oublier ce Mac".
    func forget() {
        setMusicModeOff()
        forgetToken()
        Keychain.set(nil, for: "host")
        Keychain.set(nil, for: "name")
        base = nil
        info = nil
        catalog = nil
        config = nil
        live = nil
        reachable = false
        connection = .searching
        Task { await adoptDiscoveredIfNeeded() }
    }

    private func forgetToken() {
        token = nil
        Keychain.set(nil, for: "token")
        streamer.stop()
    }

    // MARK: - HTTP

    private func fetchInfo(_ base: String) async throws -> AmbiInfo {
        guard let url = URL(string: base + "/api/info") else { throw AmbiError.notConnected }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AmbiError.notConnected }
        return try Self.decoder.decode(AmbiInfo.self, from: data)
    }

    @discardableResult
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         auth: Bool = true, timeout: TimeInterval = 6) async throws -> Data {
        guard let base, let url = URL(string: base + path) else { throw AmbiError.notConnected }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            forgetToken()
            throw AmbiError.unauthorized
        }
        guard (200..<300).contains(code) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AmbiError.server(code, message)
        }
        return data
    }

    func reloadState() async {
        guard let data = try? await request("/api/state"),
              let state = try? Self.decoder.decode(AmbiState.self, from: data) else { return }
        catalog = state.catalog ?? catalog
        config = state.config ?? config
        if let l = state.live {
            lastCfg = l.cfg ?? lastCfg
            live = withOverrides(l)
        }
    }

    // MARK: - Pairing

    func beginPairing() async throws {
        let data = try await request("/api/pair", method: "POST", body: ["device": UIDevice.current.name], auth: false)
        struct Pair: Decodable { var pairingId: String }
        pairingId = try Self.decoder.decode(Pair.self, from: data).pairingId
    }

    func confirmPairing(code: String) async throws {
        guard let pairingId else { throw AmbiError.notConnected }
        let data = try await request("/api/pair/confirm", method: "POST",
                                     body: ["pairing_id": pairingId, "code": code], auth: false)
        struct Confirmed: Decodable { var token: String; var info: AmbiInfo? }
        let result = try Self.decoder.decode(Confirmed.self, from: data)
        token = result.token
        Keychain.set(result.token, for: "token")
        info = result.info ?? info
        if info?.paired == false { info?.paired = true }
        self.pairingId = nil
        await reloadState()
        reconcile()
    }

    // MARK: - Live events (SSE), only while the Lights page is on screen

    func startEvents() {
        eventsViewers += 1
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in await self?.eventsLoop() }
    }

    func stopEvents() {
        eventsViewers = max(0, eventsViewers - 1)
        guard eventsViewers == 0 else { return }
        eventsTask?.cancel()
        eventsTask = nil
    }

    private func eventsLoop() async {
        var delay = 0.5
        while !Task.isCancelled {
            guard let base, let token, let url = URL(string: base + "/api/events?lite=1") else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if (resp as? HTTPURLResponse)?.statusCode == 401 {
                    forgetToken()
                    return
                }
                connection = .online
                delay = 0.5
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:") else { continue }
                    let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if let data = json.data(using: .utf8), let l = try? Self.decoder.decode(AmbiLive.self, from: data) {
                        apply(l)
                    }
                }
            } catch {}
            if Task.isCancelled { break }
            connection = reachable ? .reconnecting : .offline
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 8)
        }
    }

    private func apply(_ l: AmbiLive) {
        if let cfg = l.cfg {
            if let lastCfg, cfg != lastCfg { Task { await reloadState() } }
            lastCfg = cfg
        }
        if let remote = l.remote, let id = remote.id {
            if let lastRemoteId, id != lastRemoteId, let text = remote.text { showBanner(text) }
            lastRemoteId = id
        }
        live = withOverrides(l)
    }

    private func withOverrides(_ incoming: AmbiLive) -> AmbiLive {
        var l = incoming
        let now = Date()
        if let o = ledsOverride {
            if o.until > now {
                var leds = l.leds ?? .init()
                leds.running = o.on
                l.leds = leds
            } else {
                ledsOverride = nil
            }
        }
        if let o = mouseOverride {
            if o.until > now {
                var mouse = l.mouse ?? .init()
                mouse.running = o.on
                l.mouse = mouse
            } else {
                mouseOverride = nil
            }
        }
        return l
    }

    private func showBanner(_ text: String) {
        withAnimation(.spring(duration: 0.35)) { remoteBanner = text }
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { remoteBanner = nil }
        }
    }

    // MARK: - Commands (optimistic, then corrected by the live feed)

    func power(_ on: Bool) {
        // Lights off means they no longer follow the music either.
        if !on { setMusicModeOff() }
        let until = Date().addingTimeInterval(2)
        ledsOverride = (on, until)
        mouseOverride = (on, until)
        var l = live ?? AmbiLive()
        var leds = l.leds ?? .init()
        var mouse = l.mouse ?? .init()
        leds.running = on
        mouse.running = on
        l.leds = leds
        l.mouse = mouse
        live = l
        Task {
            if let data = try? await request("/api/power", method: "POST", body: ["on": on]) { applyLiveResponse(data) }
        }
    }

    func toggleMouse() {
        var l = live ?? AmbiLive()
        var mouse = l.mouse ?? .init()
        mouse.running = !(mouse.running ?? false)
        mouseOverride = (mouse.running ?? false, Date().addingTimeInterval(2))
        l.mouse = mouse
        live = l
        Task {
            if let data = try? await request("/api/mouse/toggle", method: "POST") { applyLiveResponse(data) }
        }
    }

    private func applyLiveResponse(_ data: Data) {
        struct Wrapped: Decodable { var live: AmbiLive? }
        if let l = (try? Self.decoder.decode(Wrapped.self, from: data))?.live { live = withOverrides(l) }
    }

    func setLedMode(_ id: String) {
        editLeds { $0.mode = id }
        send(["leds": ["mode": id]])
    }

    func setLedEffect(_ id: String) {
        if config?.leds?.mode == "ambient" {
            editLeds { $0.ambientEffect = id }
            send(["leds": ["ambient_effect": id]])
        } else {
            editLeds { $0.soundEffect = id }
            send(["leds": ["sound_effect": id]])
        }
    }

    func setPalette(_ id: String) {
        editLeds { $0.palette = id }
        editMouse { $0.palette = id }
        send(["leds": ["palette": id], "mouse": ["palette": id]])
    }

    func setLedColors(_ colors: [String]) {
        editLeds { $0.colors = colors }
        send(["leds": ["colors": colors]], throttle: "colors")
    }

    func setBrightness(_ v: Double) {
        editLeds { $0.brightness = v }
        editMouse { $0.brightness = v }
        send(["leds": ["brightness": v], "mouse": ["brightness": v]], throttle: "brightness")
    }

    func setSensitivity(_ v: Double) {
        editLeds { $0.sensitivity = v }
        editMouse { $0.sensitivity = v }
        send(["leds": ["sensitivity": v], "mouse": ["sensitivity": v]], throttle: "sensitivity")
    }

    func setSpeed(_ v: Double) {
        editLeds { $0.speed = v }
        send(["leds": ["speed": v]], throttle: "speed")
    }

    func setMouseMode(_ id: String) {
        editMouse { $0.mode = id }
        send(["mouse": ["mode": id]])
    }

    func setMouseEffect(_ id: String) {
        editMouse { $0.soundEffect = id }
        send(["mouse": ["sound_effect": id]])
    }

    private func editLeds(_ change: (inout AmbiConfig.Leds) -> Void) {
        var c = config ?? AmbiConfig()
        var l = c.leds ?? AmbiConfig.Leds()
        change(&l)
        c.leds = l
        config = c
    }

    private func editMouse(_ change: (inout AmbiConfig.Mouse) -> Void) {
        var c = config ?? AmbiConfig()
        var m = c.mouse ?? AmbiConfig.Mouse()
        change(&m)
        c.mouse = m
        config = c
    }

    /// Sends a partial config. Throttled patches (sliders) go out at most every 100 ms, the
    /// last value always being sent.
    private func send(_ patch: [String: Any], throttle key: String? = nil) {
        guard let key else {
            Task { _ = try? await request("/api/config", method: "POST", body: patch) }
            return
        }
        var entry = throttles[key] ?? (Date.distantPast, nil, nil)
        let elapsed = Date().timeIntervalSince(entry.last)
        if elapsed >= 0.1 {
            entry.last = Date()
            entry.pending = nil
            Task { _ = try? await request("/api/config", method: "POST", body: patch) }
        } else {
            entry.pending = patch
            if entry.task == nil {
                entry.task = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int((0.1 - elapsed) * 1000) + 5))
                    self?.flush(key)
                }
            }
        }
        throttles[key] = entry
    }

    private func flush(_ key: String) {
        guard var entry = throttles[key] else { return }
        let pending = entry.pending
        entry.pending = nil
        entry.task = nil
        entry.last = Date()
        throttles[key] = entry
        if let pending { Task { _ = try? await request("/api/config", method: "POST", body: pending) } }
    }

    // MARK: - "Lumières sur la musique"

    func setMusicMode(_ on: Bool) {
        guard on else { setMusicModeOff(); return }
        musicMode = true
        UserDefaults.standard.set(true, forKey: Self.musicKey)
        for item in PlayerManager.shared.playerItems() { AmbilightTap.attach(item) }
        editLeds { $0.mode = "sound"; $0.palette = "cover" }
        editMouse { $0.mode = "sound"; $0.palette = "cover" }
        Task {
            _ = try? await request("/api/config", method: "POST",
                                   body: ["leds": ["mode": "sound", "palette": "cover"],
                                          "mouse": ["mode": "sound", "palette": "cover"]])
            if !isOn { power(true) }
        }
        reportedTrackId = nil
        startHeartbeat()
        reconcile()
    }

    private func setMusicModeOff() {
        guard musicMode else { return }
        musicMode = false
        UserDefaults.standard.set(false, forKey: Self.musicKey)
        streamer.stop()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let current = PlayerManager.shared.current, isPaired {
            Task { _ = try? await request("/api/nowplaying", method: "POST", body: nowPlayingBody(current, playing: false)) }
        }
        reportedTrackId = nil
        reportedPlaying = nil
    }

    /// True while the app is actually feeding the Mac.
    var isStreamingMusic: Bool {
        musicMode && isPaired && reachable && PlayerManager.shared.isPlaying && !PlayerManager.shared.isRemote
    }

    private func playerChanged() {
        reconcile()
    }

    /// Starts/stops the audio stream and reports the track, from the current situation.
    private func reconcile() {
        let player = PlayerManager.shared
        let shouldStream = musicMode && isPaired && reachable && player.isPlaying && player.current != nil && !player.isRemote
        if shouldStream, !streamer.isRunning, let base, let token {
            streamer.start(base: base, token: token)
        } else if !shouldStream, streamer.isRunning {
            streamer.stop()
        }
        if musicMode && isPaired && reachable { reportNowPlaying() }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.musicMode, PlayerManager.shared.isPlaying else { continue }
                self.reportNowPlaying(force: true)
            }
        }
    }

    private func nowPlayingBody(_ track: Item, playing: Bool) -> [String: Any] {
        ["title": track.title, "artist": track.artistLine, "album": track.album ?? "",
         "playing": playing, "source": "Jellyfin"]
    }

    private func reportNowPlaying(force: Bool = false) {
        let player = PlayerManager.shared
        guard let track = player.current else { return }
        let playing = player.isPlaying
        let trackChanged = track.id != reportedTrackId
        guard force || trackChanged || playing != reportedPlaying else { return }
        reportedTrackId = track.id
        reportedPlaying = playing
        var body = nowPlayingBody(track, playing: playing)
        Task {
            if trackChanged, let url = JellyfinClient.shared.artURL(track, points: 100),
               let image = await ImageCache.shared.image(for: url),
               let jpeg = Self.resized(image, side: 300).jpegData(compressionQuality: 0.8) {
                body["artwork"] = jpeg.base64EncodedString()
            }
            _ = try? await request("/api/nowplaying", method: "POST", body: body, timeout: 10)
        }
        if musicMode, heartbeatTask == nil { startHeartbeat() }
    }

    private static func resized(_ image: UIImage, side: CGFloat) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Colors for the glow

    /// Colors the LEDs show, when known: the live palette (from the feed), else the chosen preset.
    /// nil = the "cover" palette without live data — the view then uses the artwork colors.
    var paletteColors: [Color]? {
        if let p = live?.leds?.palette {
            let colors = p.compactMap(AmbiColor.rgb).map { Color(red: $0.0, green: $0.1, blue: $0.2) }
            if colors.count >= 2 { return colors }
        }
        guard let id = config?.leds?.palette, id != "cover",
              let palette = catalog?.palettes?.first(where: { $0.id == id }), let hex = palette.colors else { return nil }
        return hex.compactMap(AmbiColor.rgb).map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    }
}
