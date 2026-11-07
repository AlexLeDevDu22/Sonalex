import Foundation
import UIKit

/// Mac only: publishes what's playing for other apps on the Mac (e.g. a notch / "Dynamic Island"
/// app like Atoll), on top of the standard macOS Now Playing info.
///
/// - `~/Library/Application Support/Musique/NowPlaying.json` is rewritten on every change;
/// - the Darwin notification `com.alexgarin.musique.nowplaying` is posted right after;
/// - the app obeys `musique://` URLs (play, pause, playpause, next, previous, open).
///
/// See docs/now-playing-mac.md.
@MainActor
final class NowPlayingExport {
    static let shared = NowPlayingExport()

    static let notificationName = "com.alexgarin.musique.nowplaying"
    /// Other apps write Command.json then post this: same commands as the musique:// URLs,
    /// without depending on macOS knowing which app opens musique:// links.
    static let commandNotificationName = "com.alexgarin.musique.command"

    private var listening = false
    private var lastCommandId: String?

    var commandFileURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("Command.json") }

    func startListeningForCommands() {
        #if targetEnvironment(macCatalyst)
        guard !listening else { return }
        listening = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { NowPlayingExport.shared.readCommand() } }
            },
            Self.commandNotificationName as CFString, nil, .deliverImmediately)
        #endif
    }

    /// Command.json: {"id": "<unique>", "command": "pause" | "play" | "playpause" | "next" | "previous"
    /// | "open" | "volume" | "transfer", "level": 0.42, "device": "<id>|this", "kind": "phone|mac"}
    func readCommand() {
        guard let data = try? Data(contentsOf: commandFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String else { return }
        let id = (json["id"] as? String) ?? "\(json["at"] ?? "")\(command)"
        guard id != lastCommandId else { return }
        lastCommandId = id
        var c = URLComponents()
        c.scheme = "sonalex"
        c.host = command
        var query: [URLQueryItem] = []
        if let level = json["level"] as? Double { query.append(URLQueryItem(name: "level", value: String(level))) }
        if let device = json["device"] as? String { query.append(URLQueryItem(name: "device", value: device)) }
        if let kind = json["kind"] as? String { query.append(URLQueryItem(name: "kind", value: kind)) }
        if !query.isEmpty { c.queryItems = query }
        if let url = c.url { Self.handle(url) }
    }

    private var lastWritten: String?

    var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Musique", isDirectory: true)
            .appendingPathComponent("NowPlaying.json")
    }

    func publish(track: Item?, isPlaying: Bool, elapsed: Double, duration: Double) {
        #if targetEnvironment(macCatalyst)
        var info: [String: Any] = [
            "isPlaying": isPlaying,
            "elapsed": (elapsed * 10).rounded() / 10,
            "duration": (duration * 10).rounded() / 10,
            "updatedAt": Date().timeIntervalSince1970,
            "bundleId": Bundle.main.bundleIdentifier ?? "",
        ]
        // Musique Connect: which device plays, and the devices it can move to.
        let connect = ConnectManager.shared
        info["connect"] = [
            "available": connect.connected,
            "thisDevice": connect.myId,
            "playingOn": connect.activeId ?? (track != nil ? connect.myId : ""),
            "isRemote": connect.isRemote,
            "devices": connect.devices.map { d -> [String: Any] in
                // This Mac's own volume is always known locally, even before the Pi echoes it.
                let volume = d.id == connect.myId ? Double(PlayerManager.shared.volume) : (d.volume ?? 1)
                return ["id": d.id, "name": d.name, "kind": d.kind, "volume": (volume * 100).rounded() / 100,
                        "isThisDevice": d.id == connect.myId, "isPlaying": d.id == connect.activeId]
            },
        ] as [String: Any]
        if let track {
            info["title"] = track.title
            info["artist"] = track.artistLine
            info["album"] = track.album ?? ""
            info["source"] = track.isExternal ? "online" : "library"
            info["id"] = track.id
            info["artworkURL"] = JellyfinClient.shared.artURL(track, points: 200)?.absoluteString ?? ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) else { return }
        // Skip identical writes (only "updatedAt" changed).
        let signature = "\(track?.id ?? "")|\(isPlaying)|\(Int(elapsed))|\(Int(duration))|"
            + "\(connect.activeId ?? "")|\(connect.devices.map { "\($0.id):\($0.name):\($0.volume ?? -1)" }.joined(separator: ","))"
            + "|\(PlayerManager.shared.volume)"
        guard signature != lastWritten else { return }
        lastWritten = signature
        MenuBarController.shared.update(track: track, isPlaying: isPlaying, elapsed: elapsed, duration: duration)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.notificationName as CFString), nil, nil, true)
        #endif
    }

    /// `musique://playpause`, `play`, `pause`, `next`, `previous`, `open` (shows Now Playing),
    /// `transfer?device=<id>` / `transfer?device=this` / `transfer?kind=phone|mac` (where it plays),
    /// `volume?level=0…1` (volume of the device that plays).
    static func handle(_ url: URL) {
        guard url.scheme == "sonalex" || url.scheme == "musique" else { return }
        let player = PlayerManager.shared
        let params = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "transfer":
            let connect = ConnectManager.shared
            var target: String?
            if let device = params["device"] { target = device == "this" ? connect.myId : device }
            if target == nil, let kind = params["kind"] {
                target = connect.devices.first { $0.kind == kind && $0.id != connect.activeId }?.id
                    ?? connect.devices.first { $0.kind == kind }?.id
            }
            if let target, target != connect.activeId { connect.transfer(to: target) }
        case "volume":
            // musique://volume?level=0.42 — on the device that plays (forwarded if it's another one).
            if let level = params["level"].flatMap(Double.init) { player.setVolume(level) }
        case "play": player.play()
        case "pause": player.pause()
        case "playpause", "toggle": player.togglePlayPause()
        case "next": player.next()
        case "previous", "prev": player.previous()
        case "open": if player.current != nil { player.showNowPlaying = true }
        default: break
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Mac only: the menu bar icon (SonalexMenuBar.bundle, AppKit). With it the app keeps running
/// once its window is closed: the music goes on, Atoll stays connected, and the window comes
/// back from the icon (or the Dock).
@MainActor
final class MenuBarController {
    static let shared = MenuBarController()
    private var bridge: MenuBarBridge?

    func start() {
        guard bridge == nil,
              let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("SonalexMenuBar.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let cls = bundle.principalClass as? NSObject.Type,
              let bridge = cls.init() as? MenuBarBridge else {
            PlayerDiagnostics.log("menuBarUnavailable", [:])
            return
        }
        self.bridge = bridge
        bridge.start { command in
            DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarController.shared.handle(command) } }
        }
        let player = PlayerManager.shared
        update(track: player.current, isPlaying: player.isPlaying, elapsed: player.currentTime, duration: player.duration)
    }

    func update(track: Item?, isPlaying: Bool, elapsed: Double, duration: Double) {
        guard let bridge else { return }
        bridge.update([
            "title": track?.title ?? "",
            "artist": track?.artistLine ?? "",
            "artworkURL": JellyfinClient.shared.artURL(track, points: 200)?.absoluteString ?? "",
            "isPlaying": isPlaying,
            "elapsed": elapsed,
            "duration": duration,
        ])
    }

    private func handle(_ command: String) {
        if command == "window" {
            showWindow()
        } else if command.hasPrefix("sonalex://") || command.hasPrefix("musique://"), let url = URL(string: command) {
            // A link from another app (Atoll…): "open" shows the app, the rest runs windowless.
            if url.host == "open" { showWindow() }
            NowPlayingExport.handle(url)
        } else if let url = URL(string: "sonalex://\(command)") {
            NowPlayingExport.handle(url)
        }
    }

    /// Brings the window back (re-created if it was closed).
    private func showWindow() {
        let app = UIApplication.shared
        let session = app.openSessions.first { $0.role == .windowApplication }
        app.requestSceneSessionActivation(session, userActivity: nil, options: nil) { _ in
            if session != nil {
                app.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
            }
        }
    }
}
#endif
