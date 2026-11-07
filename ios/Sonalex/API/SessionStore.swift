import Foundation
import Observation

struct Session: Codable, Equatable {
    var server: String
    var token: String
    var userId: String
    var userName: String
    var serverName: String
}

@Observable
@MainActor
final class SessionStore {
    static let shared = SessionStore()

    private(set) var session: Session?
    private static let key = "jm.session"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            session = try? JSONDecoder().decode(Session.self, from: data)
        }
    }

    func signIn(_ s: Session) {
        session = s
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: Self.key)
    }

    func logout() {
        guard session != nil else { return }
        ConnectManager.shared.stop()
        PlayerManager.shared.reset()
        JellyfinClient.shared.invalidateCache()
        FavoritesStore.shared.reset()
        MixStore.shared.reset()
        ServerFeatures.shared.reset()
        session = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    static var deviceId: String {
        let k = "jm.deviceId"
        if let id = UserDefaults.standard.string(forKey: k) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: k)
        return id
    }
}
