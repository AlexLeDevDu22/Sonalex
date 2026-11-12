import Foundation
import Network
import Observation

/// Can we reach the server right now? Online, unstable (answers, but slowly or not always), or
/// offline (no network, or the Pi doesn't answer). Decides whether playback sticks to the songs
/// on this device (see PlayerManager.play), so it's kept fresh: on every network change, every
/// minute, and whenever a request fails.
@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    enum Status { case online, unstable, offline }
    private(set) var status: Status = .online
    var isOffline: Bool { status == .offline }

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var pathOK = true
    /// Last probes: answer time in seconds, nil = no answer.
    @ObservationIgnored private var results: [Double?] = []
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var probing: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?

    private init() {
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in Connectivity.shared.pathChanged(ok) }
        }
        monitor.start(queue: DispatchQueue(label: "musique.connectivity"))
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await Connectivity.shared.probe() }
        }
    }

    /// Called at launch so the first decision is already informed.
    func start() {
        Task { await probe() }
    }

    /// A request just failed for a network reason: look again (at most every 5 s).
    func requestFailed() {
        guard Date().timeIntervalSince(lastProbe) > 5 else { return }
        Task { await probe() }
    }

    @ObservationIgnored private var offlineGrace: Task<Void, Never>?

    private func pathChanged(_ ok: Bool) {
        pathOK = ok
        offlineGrace?.cancel()
        offlineGrace = nil
        if ok {
            Task { await probe() }
        } else {
            // A path drop is very often a brief hand-off (Wi-Fi ⇄ cellular, a tunnel, a lift): do
            // NOT call it offline at once, or playback reacts to every hiccup. Wait a moment and
            // only commit if the network is genuinely still gone.
            results = []
            offlineGrace = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.pathOK { await self.probe() } else { self.set(.offline) }
            }
        }
    }

    func probe() async {
        if let probing { await probing.value; return }
        let task = Task { await runProbe() }
        probing = task
        await task.value
        probing = nil
    }

    private func runProbe() async {
        guard pathOK else { set(.offline); return }
        guard let server = SessionStore.shared.session?.server, let url = URL(string: server + "/System/Ping") else { return }
        // Three chances before calling it offline: a slow or hairpinned link drops the odd request,
        // and treating that as "offline" is what makes playback jump around. Being slow to declare
        // offline is fine — a real loss of network is caught by the path monitor instead.
        var took = await ping(url)
        if took == nil { took = await ping(url) }
        if took == nil { took = await ping(url) }
        lastProbe = Date()
        results = Array((results + [took]).suffix(3))
        guard let took else { set(.offline); return }
        if status == .offline { results = [took] }  // just back: older failures don't count
        let recentFailure = results.dropLast().contains { $0 == nil }
        set(took > 2.5 || recentFailure ? .unstable : .online)
    }

    private func ping(_ url: URL) async -> Double? {
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        let started = Date()
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Date().timeIntervalSince(started)
    }

    private func set(_ new: Status) {
        guard new != status else { return }
        let old = status
        status = new
        PlayerDiagnostics.log("connectivity", ["from": "\(old)", "to": "\(new)"])
        PlayerManager.shared.connectivityChanged(from: old, to: new)
    }
}
