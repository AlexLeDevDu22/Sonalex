import Foundation
import Network

/// Finds Ambilight servers announced over Bonjour (`_ambilight._tcp`).
@MainActor
final class AmbilightDiscovery {
    struct Found: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    private var browser: NWBrowser?
    private(set) var results: [Found] = []
    var onChange: (([Found]) -> Void)?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_ambilight._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let found = results.compactMap { result -> Found? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Found(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor [weak self] in
                self?.results = found
                self?.onChange?(found)
            }
        }
        b.stateUpdateHandler = { state in
            if case .failed = state {
                Task { @MainActor [weak self] in
                    self?.browser?.cancel()
                    self?.browser = nil
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// A fresh browse (after a network change the old one can go stale).
    func restart() {
        stop()
        start()
    }

    var isRunning: Bool { browser != nil }

    /// Resolves a Bonjour endpoint to "http://ip:port" (IPv4 preferred).
    nonisolated static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        let box = ResolveBox()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            box.continuation = cont
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var result: String?
                    if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                        var h: String
                        switch host {
                        case .ipv4(let a): h = "\(a)"
                        case .ipv6(let a): h = "[\(a)]"
                        case .name(let n, _): h = n
                        @unknown default: h = "\(host)"
                        }
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) } // drop interface scope
                        result = "http://\(h):\(port.rawValue)"
                    }
                    connection.cancel()
                    box.finish(result)
                case .failed, .cancelled:
                    box.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                connection.cancel()
                box.finish(nil)
            }
        }
    }
}

/// Resumes the continuation exactly once.
private final class ResolveBox: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<String?, Never>?

    func finish(_ value: String?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
