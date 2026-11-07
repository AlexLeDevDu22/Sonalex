import Foundation

/// Player events sent to the Pi (backend/…/logs/player-debug.log), to see what really happens at
/// the end of a song on the device instead of guessing. Tiny and batched; never blocks playback.
@MainActor
enum PlayerDiagnostics {
    private static var pending: [[String: Any]] = []
    private static var flushTask: Task<Void, Never>?

    static func log(_ event: String, _ info: [String: Any] = [:]) {
        let player = PlayerManager.shared
        var entry: [String: Any] = [
            "event": event,
            "at": Date().timeIntervalSince1970,
            "t": (player.currentTime * 10).rounded() / 10,
            "duration": (player.duration * 10).rounded() / 10,
            "track": player.current?.title ?? "",
            "online": player.current?.isExternal ?? false,
            "index": player.index,
            "queue": player.queue.count,
        ]
        for (k, v) in info { entry[k] = v }
        #if targetEnvironment(macCatalyst)
        entry["device"] = "mac"
        #else
        entry["device"] = "phone"
        #endif
        pending.append(entry)
        if pending.count > 200 { pending.removeFirst(pending.count - 200) }
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let batch = pending
            pending = []
            SonalexAPI.shared.sendDiagnostics(batch)
        }
    }
}
