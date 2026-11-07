import Foundation
import Observation
import UIKit
import UserNotifications

// MARK: - Models (Sonalex server, backend/api/community.py)

struct SocialSong: Codable, Hashable {
    var itemId: String?
    var title: String?
    var artist: String?
    var album: String?
    var artId: String?
    var artTag: String?
    var art: String?
    var plays: Int?
    var at: Double?
    /// The viewer's own copy of a friend's song (the same file), to play it.
    var yourItemId: String?

    @MainActor var artworkURL: URL? {
        if let artId { return JellyfinClient.shared.imageURL(id: artId, tag: artTag, points: 60) }
        return art.flatMap(URL.init(string:))
    }
}

struct SocialUser: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var provider: String?
    var admin: Bool?
    var joinedAt: Double?
    var isMe: Bool?
    var weekMinutes: Int?
    var nowPlaying: SocialSong?
    var moment: SocialSong?
}

struct ListeningStats: Decodable, Hashable {
    struct ArtistCount: Decodable, Hashable { var name: String; var plays: Int }
    var plays: Int
    var minutes: Int
    var since: Double?
    var periodDays: Int
    var periodPlays: Int
    var periodMinutes: Int
    var byDay: [Int]
    var byHour: [Int]
    var topSongs: [SocialSong]
    var topArtists: [ArtistCount]
    var recent: [SocialSong]
}

struct UserProfile: Decodable {
    var id: String
    var name: String
    var provider: String?
    var admin: Bool?
    var joinedAt: Double?
    var stats: ListeningStats
    var moment: SocialSong?
    var nowPlaying: SocialSong?
    var favorites: Int
    var library: Int
}

struct AccessRequest: Decodable, Identifiable, Hashable {
    struct Deezer: Decodable, Hashable { var id: String; var name: String }
    var id: String
    var name: String
    var provider: String
    var deezer: Deezer?
    var createdAt: Double
}

struct MeInfo: Decodable {
    var id: String
    var name: String
    var provider: String?
    var admin: Bool?
    var visible: Bool?
    var spotifyConnected: Bool?
    var deezerName: String?
    var pending: Int?
}

struct TrackSharer: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var liked: Bool
}

enum MusicService: String, CaseIterable, Identifiable {
    case spotify, deezer, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spotify: "Spotify"
        case .deezer: "Deezer"
        case .none: "None"
        }
    }
}

// MARK: - Store

/// The other people on this server (when it has several users): who they are, what they listen
/// to, and — for the server's owner — who's asking to join.
@Observable
@MainActor
final class Community {
    static let shared = Community()

    private(set) var me: MeInfo?
    private(set) var users: [SocialUser] = []
    private(set) var requests: [AccessRequest] = []

    var isAdmin: Bool { me?.admin == true }
    var friends: [SocialUser] { users.filter { $0.isMe != true } }

    private static let seenKey = "community.seenRequests"

    func refreshMe() async {
        guard ServerFeatures.shared.accounts else { return }
        me = try? await SonalexAPI.shared.fetch("/api/me")
        if isAdmin {
            Notifier.requestPermission()
            await refreshRequests()
        }
    }

    func refreshUsers() async {
        struct R: Decodable { var users: [SocialUser] }
        guard ServerFeatures.shared.accounts, let r: R = try? await SonalexAPI.shared.fetch("/api/social/users") else { return }
        users = r.users
    }

    /// The owner's pending requests; a notification for each one not seen yet (the app may have
    /// been closed when it came in).
    func refreshRequests() async {
        struct R: Decodable { var requests: [AccessRequest] }
        guard isAdmin, let r: R = try? await SonalexAPI.shared.fetch("/api/admin/requests") else { return }
        requests = r.requests
        var seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        for request in r.requests where !seen.contains(request.id) {
            Notifier.post(title: "New user", body: "\(request.name) wants to join your server", id: "request-\(request.id)")
            seen.insert(request.id)
        }
        UserDefaults.standard.set(Array(seen.suffix(200)), forKey: Self.seenKey)
    }

    /// A request just arrived (Connect told this device).
    func requestArrived() {
        Task { await refreshRequests() }
    }

    func approve(_ request: AccessRequest) async throws {
        _ = try await SonalexAPI.shared.send("/api/admin/requests/\(request.id)/approve", method: "POST", timeout: 60)
        requests.removeAll { $0.id == request.id }
        ToastCenter.shared.show("\(request.name) can now sign in", systemImage: "person.badge.plus")
        await refreshUsers()
    }

    func deny(_ request: AccessRequest) async throws {
        _ = try await SonalexAPI.shared.send("/api/admin/requests/\(request.id)/deny", method: "POST")
        requests.removeAll { $0.id == request.id }
    }

    func setVisible(_ visible: Bool) async {
        _ = try? await SonalexAPI.shared.send("/api/me/visible", method: "PUT", body: ["visible": visible])
        await refreshMe()
    }

    func profile(_ userId: String) async throws -> UserProfile {
        try await SonalexAPI.shared.fetch("/api/social/users/\(userId)")
    }

    /// The other users who have this song (one of the user's), and whether they like it.
    func sharers(of track: Item) async -> [TrackSharer] {
        struct R: Decodable { var users: [TrackSharer] }
        guard ServerFeatures.shared.accounts, !track.isExternal,
              let r: R = try? await SonalexAPI.shared.fetch("/api/social/track/\(track.id)") else { return [] }
        return r.users
    }

    func reset() {
        me = nil
        users = []
        requests = []
    }

    // MARK: Signing up (no account yet: plain requests to the server's address)

    struct ServerInfo: Decodable {
        struct Providers: Decodable { var spotify: Bool; var deezer: Bool; var none: Bool }
        var signups: Bool
        var serverName: String?
        var owner: String?
        var providers: Providers
    }

    struct SignUp: Codable {
        var server: String
        var id: String
        var secret: String
        var name: String
    }

    struct RequestStatus: Decodable { var status: String; var name: String }

    enum SignUpError: LocalizedError {
        case notJellyfin, noSonalex, closed, server(String)
        var errorDescription: String? {
            switch self {
            case .notJellyfin: "No Jellyfin server answers at this address."
            case .noSonalex: "This Jellyfin server doesn't run the Sonalex server: ask its owner for an account."
            case .closed: "This server doesn't take new users."
            case .server(let message): message
            }
        }
    }

    private static func call(_ server: String, _ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: server + "/sonalex" + path) else { throw APIError.badURL }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.unreachable
        }
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONSerialization.jsonObject(with: result.0) as? [String: Any])?["detail"] as? String
            if code == 404 && detail == nil { throw SignUpError.noSonalex }
            throw SignUpError.server(detail ?? "Server error (\(code)).")
        }
        return result.0
    }

    /// Checks the address: a Jellyfin server, with the Sonalex server, that takes new users.
    static func serverInfo(_ server: String) async throws -> ServerInfo {
        guard let url = URL(string: server + "/System/Info/Public"),
              let (_, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw SignUpError.notJellyfin }
        let info = try JSONDecoder().decode(ServerInfo.self, from: try await call(server, "/api/accounts/info"))
        guard info.signups else { throw SignUpError.closed }
        return info
    }

    static func requestAccount(server: String, name: String, password: String, service: MusicService,
                               deezer: String?) async throws -> SignUp {
        struct R: Decodable { var id: String; var secret: String; var name: String }
        var body: [String: Any] = ["name": name, "password": password, "provider": service.rawValue]
        if let deezer { body["deezer"] = deezer }
        let r = try JSONDecoder().decode(R.self, from: try await call(server, "/api/accounts/request", method: "POST", body: body))
        return SignUp(server: server, id: r.id, secret: r.secret, name: r.name)
    }

    static func status(of signUp: SignUp) async throws -> RequestStatus {
        let path = "/api/accounts/request/\(signUp.id)?secret=\(signUp.secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        return try JSONDecoder().decode(RequestStatus.self, from: try await call(signUp.server, path))
    }

    /// A request that's still waiting (the app may be closed meanwhile).
    static var pendingSignUp: SignUp? {
        get { UserDefaults.standard.data(forKey: "community.signUp").flatMap { try? JSONDecoder().decode(SignUp.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "community.signUp") }
    }
}

// MARK: - Notifications

/// Local notifications: a new user asking to join (for the owner), an account accepted. Shown
/// while the app runs or plays in the background; a server can't push to a closed app.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Shows the banners while the app is in front too.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Reporting what's played

/// Tells the server what this device plays (for the profiles and the owner's stats): each song
/// once it's over, with how long it was heard, and the song of the moment when it changes.
@MainActor
final class SocialReporter {
    static let shared = SocialReporter()

    private var timer: Timer?
    private var current: Item?
    private var listened: Double = 0
    private var startedAt = Date()
    private static let momentKey = "community.sentMoment"

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { SocialReporter.shared.tick() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { SocialReporter.shared.tick() }
        }
    }

    private func tick() {
        guard ServerFeatures.shared.accounts else { return }
        let player = PlayerManager.shared
        // The device that makes the sound reports it, not the ones controlling it.
        let track = player.isRemote ? nil : player.current
        if track?.id != current?.id {
            flush()
            current = track
            listened = 0
            startedAt = Date()
        }
        if track != nil, player.isPlaying, !player.isBuffering { listened += 5 }
        reportMoment()
    }

    private func flush() {
        guard let track = current, listened >= 10 else { return }
        var body: [String: Any] = ["title": track.title, "artist": track.artistLine, "listened": listened,
                                   "duration": track.duration, "at": startedAt.timeIntervalSince1970]
        if !track.isExternal { body["itemId"] = track.id }
        if let album = track.album { body["album"] = album }
        if let albumId = track.albumId { body["artId"] = albumId }
        if let tag = track.albumPrimaryImageTag { body["artTag"] = tag }
        if let art = track.externalArt { body["art"] = art }
        Task { _ = try? await SonalexAPI.shared.send("/api/me/plays", method: "POST", body: body) }
    }

    private func reportMoment() {
        let moment = MomentFavorite.shared.current
        guard moment?.id != UserDefaults.standard.string(forKey: Self.momentKey) else { return }
        UserDefaults.standard.set(moment?.id, forKey: Self.momentKey)
        var body: [String: Any] = [:]
        if let m = moment {
            body = ["title": m.title, "artist": m.artistLine]
            if !m.isExternal { body["itemId"] = m.id }
            if let albumId = m.albumId { body["artId"] = albumId }
            if let tag = m.albumPrimaryImageTag { body["artTag"] = tag }
            if let art = m.externalArt { body["art"] = art }
        }
        Task { _ = try? await SonalexAPI.shared.send("/api/me/moment", method: "PUT", body: body) }
    }
}
