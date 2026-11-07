import Foundation
import UIKit

enum APIError: LocalizedError {
    case notLoggedIn, unauthorized, badURL, unreachable, badCredentials
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Not signed in."
        case .unauthorized: "Your session expired, please sign in again."
        case .badURL: "Invalid server address."
        case .unreachable: "Can’t reach the server. Check the address and that you’re on the right network."
        case .badCredentials: "Wrong username or password."
        case .http(let code): "Server error (\(code))."
        }
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

@MainActor
final class JellyfinClient {
    static let shared = JellyfinClient()

    static let client = "Sonalex"
    static let version = "1.0.0"
    static let fields = "Genres,DateCreated,ChildCount"

    /// Jellyfin speaks PascalCase JSON; map "AlbumArtist" → "albumArtist".
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let raw = keys.last!.stringValue
            guard let first = raw.first else { return AnyKey(stringValue: raw) }
            return AnyKey(stringValue: first.lowercased() + raw.dropFirst())
        }
        return d
    }()

    private let cache = ResponseCache.shared
    /// Identical GETs issued at the same time share one network request.
    private var inflight: [String: Task<Data, Error>] = [:]

    private var session: Session? { SessionStore.shared.session }

    func invalidateCache() { cache.removeAll() }

    // MARK: - Plumbing

    static func authHeader(token: String?) -> String {
        var h = "MediaBrowser Client=\"\(client)\", Device=\"\(UIDevice.current.name)\", DeviceId=\"\(SessionStore.deviceId)\", Version=\"\(version)\""
        if let token { h += ", Token=\"\(token)\"" }
        return h
    }

    private func makeURL(_ path: String, _ query: [String: String]) throws -> URL {
        guard let s = session else { throw APIError.notLoggedIn }
        guard var c = URLComponents(string: s.server + path) else { throw APIError.badURL }
        if !query.isEmpty {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = c.url else { throw APIError.badURL }
        return url
    }

    /// `invalidates`: for writes, which cached responses become stale — `""` = all, a fragment = URLs
    /// containing it, `nil` = none.
    @discardableResult
    private func send(_ path: String, method: String = "GET", query: [String: String] = [:],
                      body: [String: Any]? = nil, cacheable: Bool = true, invalidates: String? = "") async throws -> Data {
        let url = try makeURL(path, query)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue(Self.authHeader(token: session?.token), forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        guard method == "GET" else {
            // No connection: fail at once instead of waiting for the timeout.
            if Connectivity.shared.isOffline { throw APIError.unreachable }
            let data = try await perform(req)
            if let invalidates {
                if invalidates.isEmpty { cache.removeAll() } else { cache.remove(matching: invalidates) }
            }
            return data
        }

        let key = url.absoluteString
        guard cacheable else {
            // Always fetched fresh, but the last answer is kept: offline, the page still opens
            // (a downloaded playlist must play without any network).
            if Connectivity.shared.isOffline, let hit = cache.get(key) { return hit.data }
            do {
                let data = try await perform(req)
                cache.set(key, data)
                return data
            } catch APIError.unreachable {
                if let hit = cache.get(key) { return hit.data }
                throw APIError.unreachable
            }
        }
        if let hit = cache.get(key) {
            // Stale-while-revalidate: answer now, refresh in the background once per day.
            if hit.date < LibrarySync.lastBoundary(), inflight[key] == nil { revalidate(key, req) }
            return hit.data
        }
        if let running = inflight[key] { return try await running.value }
        let task = Task { try await self.perform(req) }
        inflight[key] = task
        defer { inflight[key] = nil }
        let data = try await task.value
        cache.set(key, data)
        return data
    }

    private func revalidate(_ key: String, _ req: URLRequest) {
        let task = Task { try await self.perform(req) }
        inflight[key] = task
        Task {
            defer { inflight[key] = nil }
            guard let data = try? await task.value else { return }
            cache.set(key, data)
            LibrarySync.shared.scheduleBump()
        }
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch {
            Connectivity.shared.requestFailed()
            throw APIError.unreachable
        }
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            SessionStore.shared.logout()
            throw APIError.unauthorized
        }
        guard (200..<300).contains(code) else { throw APIError.http(code) }
        return result.0
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], cacheable: Bool = true) async throws -> T {
        let data = try await send(path, query: query, cacheable: cacheable)
        return try Self.decoder.decode(T.self, from: data)
    }

    private var userId: String { session?.userId ?? "" }

    // MARK: - Auth

    static func normalize(server input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func login(server input: String, username: String, password: String) async throws -> Session {
        let server = Self.normalize(server: input)
        guard let infoURL = URL(string: server + "/System/Info/Public"),
              let authURL = URL(string: server + "/Users/AuthenticateByName") else { throw APIError.badURL }

        struct PublicInfo: Decodable { var serverName: String? }
        let info: PublicInfo
        do {
            let (data, resp) = try await URLSession.shared.data(from: infoURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.unreachable }
            info = try Self.decoder.decode(PublicInfo.self, from: data)
        } catch {
            throw APIError.unreachable
        }

        var req = URLRequest(url: authURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.authHeader(token: nil), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { throw APIError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.badCredentials }
        guard code == 200 else { throw APIError.http(code) }

        struct AuthResult: Decodable {
            struct User: Decodable { var id: String; var name: String }
            var accessToken: String
            var user: User
        }
        let auth = try Self.decoder.decode(AuthResult.self, from: data)
        return Session(server: server, token: auth.accessToken, userId: auth.user.id,
                       userName: auth.user.name, serverName: info.serverName ?? "Jellyfin")
    }

    func logoutRemote() async {
        _ = try? await send("/Sessions/Logout", method: "POST", invalidates: nil)
    }

    // MARK: - Images & streaming

    private static let sizes = [120, 300, 600, 1000]

    /// `points` is the on-screen size; the request is scaled for a 3x display.
    func imageURL(id: String, tag: String?, points: CGFloat, type: String = "Primary") -> URL? {
        guard let s = session else { return nil }
        let want = Int(points * 3)
        let px = Self.sizes.first { $0 >= want } ?? Self.sizes.last!
        var c = URLComponents(string: "\(s.server)/Items/\(id)/Images/\(type)")
        var q = [URLQueryItem(name: "fillWidth", value: "\(px)"),
                 URLQueryItem(name: "fillHeight", value: "\(px)"),
                 URLQueryItem(name: "quality", value: "90")]
        if let tag { q.append(URLQueryItem(name: "tag", value: tag)) }
        c?.queryItems = q
        return c?.url
    }

    /// Best artwork for any item; songs use their album cover.
    func artURL(_ item: Item?, points: CGFloat) -> URL? {
        guard let item else { return nil }
        if let art = item.externalArt { return URL(string: art) }
        if item.isSong, let albumId = item.albumId, let tag = item.albumPrimaryImageTag {
            return imageURL(id: albumId, tag: tag, points: points)
        }
        if let tag = item.imageTags?["Primary"] { return imageURL(id: item.id, tag: tag, points: points) }
        if let albumId = item.albumId, let tag = item.albumPrimaryImageTag {
            return imageURL(id: albumId, tag: tag, points: points)
        }
        if let tag = item.backdropImageTags?.first {
            return imageURL(id: item.id, tag: tag, points: points, type: "Backdrop")
        }
        // Artist references coming from songs carry no tag: try anyway, ArtworkView handles a 404.
        if item.isArtist { return imageURL(id: item.id, tag: nil, points: points) }
        return nil
    }

    func streamURL(for item: Item, playSessionId: String) -> URL? {
        guard let s = session else { return nil }
        var c = URLComponents(string: "\(s.server)/Audio/\(item.id)/universal")
        c?.queryItems = [
            URLQueryItem(name: "UserId", value: s.userId),
            URLQueryItem(name: "DeviceId", value: SessionStore.deviceId),
            URLQueryItem(name: "ApiKey", value: s.token),
            URLQueryItem(name: "PlaySessionId", value: playSessionId),
            URLQueryItem(name: "MaxStreamingBitrate", value: "140000000"),
            // Everything AVPlayer decodes natively is direct-played, the rest is transcoded to AAC over HLS.
            URLQueryItem(name: "Container", value: "mp3,aac,m4a|aac,m4b|aac,flac,alac,m4a|alac,wav,aiff"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
        ]
        return c?.url
    }

    /// The song's own file (direct, no transcoding): recorded while it plays (CachingLoader).
    func fileURL(for item: Item) -> URL? {
        guard let s = session, var c = URLComponents(string: "\(s.server)/Audio/\(item.id)/stream") else { return nil }
        c.queryItems = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "ApiKey", value: s.token)]
        return c.url
    }

    /// Compact copy for downloads of heavy files: AAC 160 kbit/s.
    func compactFileURL(for item: Item) -> URL? {
        guard let s = session, var c = URLComponents(string: "\(s.server)/Audio/\(item.id)/stream.m4a") else { return nil }
        c.queryItems = [URLQueryItem(name: "audioCodec", value: "aac"), URLQueryItem(name: "audioBitRate", value: "160000"),
                        URLQueryItem(name: "audioChannels", value: "2"), URLQueryItem(name: "ApiKey", value: s.token)]
        return c.url
    }

    // MARK: - Library

    func items(_ q: [String: String], cacheable: Bool = true) async throws -> [Item] {
        try await page(q, cacheable: cacheable).items
    }

    /// One page of `/Items`; pass `StartIndex` / `Limit` in `q` and read `totalRecordCount`.
    func page(_ q: [String: String], cacheable: Bool = true) async throws -> ItemsResult {
        var query = ["userId": userId, "Recursive": "true", "Fields": Self.fields, "ImageTypeLimit": "1",
                     "EnableImageTypes": "Primary,Backdrop", "EnableTotalRecordCount": q["StartIndex"] == nil ? "false" : "true"]
        query.merge(q) { _, new in new }
        return try await get("/Items", query, cacheable: cacheable)
    }

    func item(_ id: String) async throws -> Item {
        try await get("/Items/\(id)", ["userId": userId])
    }

    func albumTracks(_ albumId: String) async throws -> [Item] {
        try await items(["ParentId": albumId, "IncludeItemTypes": "Audio", "SortBy": "ParentIndexNumber,IndexNumber,SortName"])
    }

    func playlistTracks(_ playlistId: String, cacheable: Bool = false) async throws -> [Item] {
        let r: ItemsResult = try await get("/Playlists/\(playlistId)/Items", ["userId": userId, "Fields": Self.fields],
                                           cacheable: cacheable)
        return r.items
    }

    // MARK: - Stations

    /// A station is the artist only: all their tracks, shuffled.
    func artistStation(_ artistId: String) async throws -> [Item] {
        try await artistTracks(artistId).shuffled()
    }

    func artistTracks(_ artistId: String) async throws -> [Item] {
        try await items(["ArtistIds": artistId, "IncludeItemTypes": "Audio",
                         "SortBy": "Album,ParentIndexNumber,IndexNumber,SortName"])
    }

    func albumArtists(_ q: [String: String] = [:]) async throws -> [Item] {
        var query = ["userId": userId, "SortBy": "SortName", "Fields": Self.fields]
        query.merge(q) { _, new in new }
        let r: ItemsResult = try await get("/Artists/AlbumArtists", query)
        return r.items
    }

    func instantMix(_ id: String) async throws -> [Item] {
        let r: ItemsResult = try await get("/Items/\(id)/InstantMix", ["userId": userId, "Limit": "80", "Fields": Self.fields],
                                           cacheable: false)
        return r.items
    }

    func similar(_ id: String, limit: Int = 12) async throws -> [Item] {
        let r: ItemsResult = try await get("/Items/\(id)/Similar", ["userId": userId, "Limit": "\(limit)", "Fields": Self.fields])
        return r.items
    }

    func genres() async throws -> [Item] {
        let r: ItemsResult = try await get("/MusicGenres", ["userId": userId, "SortBy": "SortName"])
        return r.items
    }

    func lyrics(_ id: String) async throws -> [LyricLine]? {
        if id.contains(":") { return try await SonalexAPI.shared.lyrics(id) }
        do {
            let r: LyricsResponse = try await get("/Audio/\(id)/Lyrics")
            return (r.lyrics?.isEmpty ?? true) ? nil : r.lyrics
        } catch APIError.http(let code) where code == 404 {
            return nil
        }
    }

    struct SearchResults {
        var artists: [Item] = []
        var albums: [Item] = []
        var songs: [Item] = []
        var playlists: [Item] = []
        var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty && playlists.isEmpty }
    }

    func search(_ term: String) async throws -> SearchResults {
        async let artists: ItemsResult = get("/Artists", ["userId": userId, "searchTerm": term, "Limit": "20", "Fields": Self.fields])
        async let albums = items(["searchTerm": term, "IncludeItemTypes": "MusicAlbum", "Limit": "24"])
        async let songs = items(["searchTerm": term, "IncludeItemTypes": "Audio", "Limit": "60"])
        async let playlists = items(["searchTerm": term, "IncludeItemTypes": "Playlist", "Limit": "20"])
        return try await SearchResults(artists: artists.items, albums: albums, songs: songs, playlists: playlists)
    }

    /// Every playable track behind an item.
    func tracks(for item: Item) async throws -> [Item] {
        switch item.type {
        case ItemKind.song: return [item]
        case ItemKind.album: return try await albumTracks(item.id)
        case ItemKind.playlist: return try await playlistTracks(item.id)
        case ItemKind.artist: return try await artistTracks(item.id)
        case ItemKind.genre:
            return try await items(["GenreIds": item.id, "IncludeItemTypes": "Audio", "SortBy": "Random", "Limit": "300"],
                                   cacheable: false)
        default: return []
        }
    }

    // MARK: - Mutations

    func setFavorite(_ id: String, _ fav: Bool) async throws {
        try await send("/UserFavoriteItems/\(id)", method: fav ? "POST" : "DELETE", query: ["userId": userId],
                       invalidates: "IsFavorite")
    }

    @discardableResult
    func createPlaylist(name: String, ids: [String]) async throws -> String? {
        let data = try await send("/Playlists", method: "POST",
                                  body: ["Name": name, "Ids": ids, "UserId": userId, "MediaType": "Audio"],
                                  invalidates: "Playlist")
        struct Created: Decodable { var id: String? }
        let id = (try? Self.decoder.decode(Created.self, from: data))?.id
        if let id { SonalexAPI.shared.syncPlaylist(id) }
        return id
    }

    func addToPlaylist(_ playlistId: String, ids: [String]) async throws {
        try await send("/Playlists/\(playlistId)/Items", method: "POST",
                       query: ["ids": ids.joined(separator: ","), "userId": userId], invalidates: "Playlist")
        SonalexAPI.shared.syncPlaylist(playlistId)
    }

    func removeFromPlaylist(_ playlistId: String, entryIds: [String]) async throws {
        try await send("/Playlists/\(playlistId)/Items", method: "DELETE", query: ["entryIds": entryIds.joined(separator: ",")],
                       invalidates: "Playlist")
        SonalexAPI.shared.syncPlaylist(playlistId)
    }

    /// Only used for playlists.
    func deleteItem(_ id: String) async throws {
        try await send("/Items/\(id)", method: "DELETE")
        SonalexAPI.shared.syncPlaylist(id)
    }

    // MARK: - Playback reporting (feeds "recently played" & play counts)

    private func report(_ path: String, itemId: String, sid: String, seconds: Double, paused: Bool) {
        guard !itemId.contains(":") else { return } // online songs aren't Jellyfin items
        let body: [String: Any] = [
            "ItemId": itemId, "PlaySessionId": sid,
            "PositionTicks": Int64(max(0, seconds) * 10_000_000),
            "IsPaused": paused, "CanSeek": true, "PlayMethod": "DirectPlay",
        ]
        Task { _ = try? await self.send(path, method: "POST", body: body, cacheable: false, invalidates: nil) }
    }

    func reportStart(_ id: String, sid: String, seconds: Double, paused: Bool) {
        report("/Sessions/Playing", itemId: id, sid: sid, seconds: seconds, paused: paused)
    }

    func reportProgress(_ id: String, sid: String, seconds: Double, paused: Bool) {
        report("/Sessions/Playing/Progress", itemId: id, sid: sid, seconds: seconds, paused: paused)
    }

    func reportStopped(_ id: String, sid: String, seconds: Double) {
        report("/Sessions/Playing/Stopped", itemId: id, sid: sid, seconds: seconds, paused: false)
    }
}
