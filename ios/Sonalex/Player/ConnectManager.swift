import Foundation
import Network
import Observation
import UIKit

/// What the playing device shares with the others (Musique Connect).
struct ConnectState: Codable {
    var queue: [QueueEntry]
    var original: [QueueEntry]?
    var index: Int
    var isPlaying: Bool
    var time: Double
    var timestamp: Double
    var duration: Double
    var shuffle: Bool
    var repeatMode: RepeatMode
    var autoplay: Bool
    var source: String?
    var sourceId: String?
    /// The player's volume, carried over when playback moves to another device.
    var volume: Double?
}

/// An action sent from a remote device to the playing one.
enum ConnectCommand: Codable {
    case play, pause, toggle, next, previous
    case seek(Double)
    case jump(UUID)
    case playTracks(tracks: [Item], startAt: Int, shuffle: Bool?, source: String?, sourceId: String?, autoplay: Bool)
    case playNext([Item])
    case addToQueue([Item])
    case remove([UUID])
    case move(from: [Int], to: Int)
    case clearUpcoming
    case toggleShuffle
    case setRepeat(RepeatMode)
    case toggleAutoplay
    case setVolume(Double)
}

/// "Sonalex Connect": every device of the account stays connected to the server; one device plays,
/// the others show what it plays and control it. Playback can be moved from one to another.
@Observable
@MainActor
final class ConnectManager {
    static let shared = ConnectManager()

    struct Device: Decodable, Identifiable, Hashable {
        var id: String
        var name: String
        var kind: String
        /// The app's playback volume on that device (0…1).
        var volume: Double?

        var systemImage: String {
            switch kind {
            case "mac": "laptopcomputer"
            case "tablet": "ipad"
            default: "iphone"
            }
        }
    }

    private(set) var devices: [Device] = []
    private(set) var activeId: String?
    private(set) var connected = false

    let myId = SessionStore.deviceId

    /// Another device is playing: this one is a remote control. Survives a short reconnect
    /// (activeId is only cleared once the link has been down for a few seconds).
    var isRemote: Bool { activeId != nil && activeId != myId }
    var activeDevice: Device? { devices.first { $0.id == activeId } }
    var hasOtherDevices: Bool { devices.contains { $0.id != myId } }

    static var deviceKind: String {
        #if targetEnvironment(macCatalyst)
        return "mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
        #endif
    }

    private static let nameKey = "connect.deviceName"

    /// Name shown to the other devices: the one set in the app, else the best guess.
    static var deviceName: String {
        if let custom = UserDefaults.standard.string(forKey: nameKey)?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty { return custom }
        return defaultDeviceName
    }

    /// iOS only gives apps the real device name with an entitlement Apple doesn't grant to free
    /// accounts, so: "iPhone de Alex" from the Jellyfin user. On the Mac, the computer's name.
    static var defaultDeviceName: String {
        let generic: Set<String> = ["", "iPhone", "iPad", "Mac", "My Mac"]
        #if targetEnvironment(macCatalyst)
        // The host name varies (Bonjour name, DNS reverse name like "…ipv6.abo.wanadoo.fr"):
        // only trust a "Something.local" name, and keep the first good one for good.
        if let saved = UserDefaults.standard.string(forKey: "connect.autoMacName") { return saved }
        var host = ProcessInfo.processInfo.hostName
        guard host.hasSuffix(".local") else {
            return SessionStore.shared.session.map { "Mac de \($0.userName.prefix(1).uppercased() + $0.userName.dropFirst())" } ?? "Mac"
        }
        host.removeLast(6)
        host = host.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        if !host.isEmpty, host.lowercased() != "localhost", !host.contains(".") {
            // "macbook air de alex" → "MacBook Air de Alex"
            let name = host.split(separator: " ").map { word -> String in
                let w = String(word)
                if w.lowercased() == "macbook" { return "MacBook" }
                if w.lowercased() == "imac" { return "iMac" }
                if ["de", "du", "des", "d'"].contains(w.lowercased()) { return w.lowercased() }
                return w.first.map { String($0).uppercased() + w.dropFirst() } ?? w
            }.joined(separator: " ")
            UserDefaults.standard.set(name, forKey: "connect.autoMacName")
            return name
        }
        #endif
        let system = UIDevice.current.name
        if !generic.contains(system) { return system }
        let model = deviceKind == "mac" ? "Mac" : deviceKind == "tablet" ? "iPad" : "iPhone"
        if let user = SessionStore.shared.session?.userName, !user.isEmpty {
            return "\(model) de \(user.prefix(1).uppercased() + user.dropFirst())"
        }
        return model
    }

    /// Renames this device (empty = back to the automatic name) and tells the other devices.
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.nameKey)
        socket?.cancel(with: .goingAway, reason: nil) // the loop reconnects with the new name
    }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgress = Date.distantPast
    /// Last sign of life from the Pi (message or pong): a socket can die silently (Mac asleep,
    /// iPhone suspended, Wi-Fi change) and must then be replaced quickly.
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var justConnected = false
    @ObservationIgnored private var wakeRequested = false
    @ObservationIgnored private var observing = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private var lastForcedReconnect = Date.distantPast
    @ObservationIgnored private var graceTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        observeLifecycle()
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Re-check the link whenever it may have broken: app back to the front, Mac awake, network change.
    private func observeLifecycle() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willEnterForegroundNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ConnectManager.shared.checkConnection() }
            }
        }
        pathMonitor.pathUpdateHandler = { path in
            // Only real network changes (a Mac reports many minor path updates: AirDrop, VPN…).
            let signature = "\(path.status)|\(path.availableInterfaces.filter { $0.type != .other }.map(\.name).sorted())"
            Task { @MainActor in
                let me = ConnectManager.shared
                guard path.status == .satisfied, signature != me.lastPathSignature else {
                    me.lastPathSignature = signature
                    return
                }
                let first = me.lastPathSignature == nil
                me.lastPathSignature = signature
                if !first { me.checkConnection() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "connect.path"))
    }

    /// Ping the Pi; if it doesn't answer quickly (or `force`), drop the socket and reconnect now.
    func checkConnection(force: Bool = false) {
        guard loop != nil else { start(); return }
        guard let socket, connected, !force else {
            reconnectNow()
            return
        }
        let sentAt = Date()
        socket.sendPing { error in
            Task { @MainActor in
                if error == nil { ConnectManager.shared.lastActivity = Date() }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if self.lastActivity < sentAt { self.reconnectNow() }
        }
    }

    private func reconnectNow() {
        // Never more than one forced reconnect every 10 s.
        guard Date().timeIntervalSince(lastForcedReconnect) > 10 || !connected else { return }
        lastForcedReconnect = Date()
        wakeRequested = true
        socket?.cancel(with: .goingAway, reason: nil)
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let wasRemote = isRemote
        connected = false
        devices = []
        activeId = nil
        if wasRemote { PlayerManager.shared.remoteEnded() }
    }

    private func run() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            // No Sonalex server next to this Jellyfin: no Connect (checked again now and then).
            guard ServerFeatures.shared.companion, let s = SessionStore.shared.session,
                  var c = URLComponents(string: s.server + "/sonalex/api/connect") else {
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            c.scheme = c.scheme == "https" ? "wss" : "ws"
            c.queryItems = [URLQueryItem(name: "ApiKey", value: s.token), URLQueryItem(name: "deviceId", value: myId),
                            URLQueryItem(name: "name", value: Self.deviceName),
                            URLQueryItem(name: "kind", value: Self.deviceKind),
                            URLQueryItem(name: "volume", value: String(format: "%.2f", PlayerManager.shared.volume))]
            guard let url = c.url else { return }
            let task = URLSession.shared.webSocketTask(with: url)
            socket = task
            task.resume()
            connected = true
            graceTask?.cancel()
            justConnected = true
            lastActivity = Date()
            // Heartbeat: a silent dead socket gets replaced within ~30 s even without any event.
            let heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, self.socket === task else { return }
                    task.sendPing { error in
                        Task { @MainActor in
                            if error == nil { ConnectManager.shared.lastActivity = Date() }
                        }
                    }
                    if Date().timeIntervalSince(self.lastActivity) > 30 { task.cancel(with: .goingAway, reason: nil) }
                }
            }
            // Visualizer: while this device plays, send its bars ~20×/s so the others show the same.
            let viz = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self, self.socket === task else { return }
                    guard self.activeId == self.myId, self.hasOtherDevices, PlayerManager.shared.isPlaying,
                          let bands = AmbilightAudioSink.shared.bands(localDelay: EqualizerBars.outputDelay) else { continue }
                    self.send(["type": "viz", "b": bands.map { ($0 * 100).rounded() / 100 }])
                }
            }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    backoff = 1
                    lastActivity = Date()
                    if case .string(let text) = message { handle(text) }
                }
            } catch {}
            heartbeat.cancel()
            viz.cancel()
            connected = false
            // Keep showing the other device for a few seconds: a quick reconnect must not make the
            // interface flip to "paused" and back.
            graceTask?.cancel()
            graceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled, !self.connected else { return }
                let wasRemote = self.isRemote
                self.devices = []
                self.activeId = nil
                if wasRemote { PlayerManager.shared.remoteEnded() }
            }
            // Wait before retrying — unless something asked to reconnect right away.
            let until = Date().addingTimeInterval(wakeRequested ? 0.2 : backoff)
            while Date() < until, !wakeRequested, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if wakeRequested {
                wakeRequested = false
                backoff = 1
            } else {
                backoff = min(backoff * 2, 15)
            }
        }
    }

    // MARK: Incoming

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }
        let player = PlayerManager.shared

        switch type {
        case "devices":
            let wasRemote = isRemote
            devices = decode([Device].self, msg["devices"]) ?? []
            let newActive = msg["active"] as? String
            // Don't lose our own "active" status to a listing sent before our claim was seen.
            if !(activeId == myId && newActive == nil) { activeId = newActive }
            // Only one device may make sound: if another one started playing while we were away
            // (asleep, offline…), it wins and this one stops.
            if let active = activeId, active != myId, player.hasLocalAudio { player.releaseToRemote() }
            // Back online with a song loaded here and nobody else playing: we are the playing
            // device again. Said to the Pi even if we still think we're active — after a restart
            // of the Pi (or a long cut) it has forgotten, and the other devices saw nothing.
            if justConnected {
                justConnected = false
                if newActive == nil, player.hasLocalAudio, activeId == myId || player.isPlaying { claimIfNeeded(force: true) }
            }
            if wasRemote && !isRemote { player.remoteEnded() }
            player.refreshNowPlaying()

        case "state":
            if let from = msg["from"] as? String, from != myId { activeId = from }
            if isRemote, let state = decode(ConnectState.self, msg["state"]) { player.applyRemote(state) }

        case "progress":
            guard isRemote else { return }
            player.applyRemoteProgress(time: msg["time"] as? Double, isPlaying: msg["isPlaying"] as? Bool,
                                       duration: msg["duration"] as? Double, index: msg["index"] as? Int)

        case "viz":
            if isRemote, let bands = msg["b"] as? [Double] { AmbilightAudioSink.shared.pushRemote(bands) }

        case "command":
            guard !isRemote, let command = decode(ConnectCommand.self, msg["command"]) else { return }
            player.execute(command)

        case "takeover":
            activeId = myId
            if let state = decode(ConnectState.self, msg["state"]) { player.takeOver(state) }

        case "release":
            if activeId == myId { activeId = nil }
            player.releaseToRemote()

        case "favorite":
            // Another device (un)favorited a song: show it here at once.
            if let ids = msg["ids"] as? [String], let value = msg["value"] as? Bool {
                FavoritesStore.shared.applyRemote(ids: ids, value: value)
            }

        default:
            break
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JellyfinClient.decoder.decode(T.self, from: data)
    }

    // MARK: Outgoing

    private func send(_ msg: [String: Any]) {
        guard connected, let socket, let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func encoded<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// This device starts making sound: it becomes the playing device (the previous one stops).
    func claimIfNeeded(force: Bool = false) {
        guard connected, force || activeId != myId else { return }
        activeId = myId
        send(["type": "claim"])
        stateDidChange()
    }

    /// Queue / track changed on the playing device: share it (debounced).
    func stateDidChange() {
        guard connected, activeId == myId else { return }
        stateTask?.cancel()
        stateTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let state = encoded(PlayerManager.shared.connectSnapshot()) else { return }
            send(["type": "state", "state": state])
        }
    }

    /// Position / play-pause on the playing device (immediately on changes, else every few seconds).
    func sendProgress(force: Bool = false) {
        guard connected, activeId == myId, hasOtherDevices else { return }
        guard force || Date().timeIntervalSince(lastProgress) > 4 else { return }
        lastProgress = Date()
        let p = PlayerManager.shared
        send(["type": "progress", "time": p.currentTime, "isPlaying": p.isPlaying, "duration": p.duration, "index": p.index])
    }

    /// This device's playback volume changed: the others (and Atoll) show it.
    func reportVolume(_ level: Double) {
        send(["type": "volume", "level": (level * 100).rounded() / 100])
    }

    /// Tells the other devices a song's favorite state changed (`ids`: Jellyfin id, and the
    /// online id it had before being saved, if any).
    func sendFavorite(ids: [String], value: Bool) {
        send(["type": "favorite", "ids": ids, "value": value])
    }

    func send(_ command: ConnectCommand) {
        guard let payload = encoded(command) else { return }
        send(["type": "command", "command": payload])
    }

    /// Move playback to another device (or to this one).
    func transfer(to deviceId: String) {
        send(["type": "transfer", "to": deviceId])
    }
}

#if !targetEnvironment(macCatalyst)
import AVFoundation

/// iPhone, paused in the background: iOS suspends the app within seconds and its link to the Pi
/// drops, so "play" on the Mac couldn't reach it (and the Mac started playing by itself). While
/// paused with other devices around, inaudible audio keeps it awake and reachable for 15 min.
@MainActor
final class StayReachable {
    static let shared = StayReachable()
    private var silence: AVAudioPlayer?
    private var until = Date.distantPast
    private var timer: Timer?

    func paused() {
        let connect = ConnectManager.shared
        guard connect.connected, connect.activeId == connect.myId, connect.hasOtherDevices else { return }
        until = Date().addingTimeInterval(15 * 60)
        if silence == nil {
            silence = try? AVAudioPlayer(data: Self.silentWAV())
            silence?.numberOfLoops = -1
            silence?.volume = 0
        }
        silence?.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { StayReachable.shared.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        silence?.stop()
    }

    private func check() {
        let connect = ConnectManager.shared
        if Date() > until || PlayerManager.shared.isPlaying || connect.activeId != connect.myId { stop() }
    }

    /// 1 s of 8 kHz 16-bit mono silence.
    private static func silentWAV() -> Data {
        let samples = 8000, bytes = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        d.append(Data(count: bytes))
        return d
    }
}
#endif
