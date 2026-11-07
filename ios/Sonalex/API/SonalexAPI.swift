import Foundation

// MARK: - Online catalog models (served by the Musique API on the Pi)

struct OnlineRef: Decodable, Hashable {
    var id: String?
    var name: String
}

struct OnlineAlbumRef: Decodable, Hashable {
    var id: String?
    var name: String?
    var image: String?
}

struct OnlineTrack: Decodable, Hashable, Identifiable {
    var key: String
    var title: String
    var artists: [OnlineRef]
    var album: OnlineAlbumRef?
    var durationMs: Int?
    var explicit: Bool?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    /// The downloaded copy, when the song is already in the library.
    var jellyfin: Item?

    var id: String { key }

    /// What the player and the lists use: the local Jellyfin item when downloaded, else a streamable item.
    var item: Item {
        if var local = jellyfin {
            // Songs downloaded by the sync carry no track number tag: use the catalog's.
            if local.indexNumber == nil { local.indexNumber = trackNumber }
            if local.parentIndexNumber == nil { local.parentIndexNumber = discNumber }
            return local
        }
        let refs = artists.map { NameId(name: $0.name, id: $0.id ?? "name:\($0.name)") }
        return Item(id: key, name: title, type: ItemKind.song, album: album?.name, albumId: album?.id,
                    albumArtist: artists.first?.name, albumArtists: refs.prefix(1).map { $0 }, artistItems: refs,
                    runTimeTicks: durationMs.map { Int64($0) * 10_000 }, productionYear: year,
                    indexNumber: trackNumber, parentIndexNumber: discNumber,
                    externalArt: album?.image, externalKey: key)
    }
}

struct OnlineAlbum: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var artist: String?
    var artistId: String?
    var image: String?
    var year: Int?
    var type: String?
    var totalTracks: Int?
}

struct OnlineArtist: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var image: String?
    var genres: [String]?
}

struct SongCredits: Decodable {
    struct Person: Decodable, Hashable { var name: String; var image: String? }
    struct Section: Decodable, Hashable { var role: String; var people: [Person] }
    var found: Bool
    var source: String?
    var url: String?
    var releaseDate: String?
    var album: String?
    var sections: [Section]
}

struct DailyPicks: Decodable, Hashable {
    var date: String
    var artist: OnlineArtist?
    var discover: OnlineArtist?
    var because: String?
}

struct OnlinePlaylist: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var owner: String?
    var image: String?
    var totalTracks: Int?
    var description: String?
}

struct OnlineSearch: Decodable {
    var tracks: [OnlineTrack] = []
    var artists: [OnlineArtist] = []
    var albums: [OnlineAlbum] = []
    var playlists: [OnlinePlaylist]? = nil

    var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && albums.isEmpty && (playlists ?? []).isEmpty }
}

struct OnlinePlaylistPage: Decodable {
    var playlist: OnlinePlaylist
    var tracks: [OnlineTrack]
}

struct OnlineArtistPage: Decodable {
    var artist: OnlineArtist
    var top: [OnlineTrack]
    var albums: [OnlineAlbum]
    var singles: [OnlineAlbum]
}

struct OnlineAlbumPage: Decodable {
    var album: OnlineAlbum
    var tracks: [OnlineTrack]
}

extension NameId {
    /// Artists coming from the online catalog ("sp:…" / "name:…") open the online artist page.
    var isOnline: Bool { id.hasPrefix("sp:") || id.hasPrefix("name:") }
}

extension Item {
    /// Page to open for one of this item's artists (library or online).
    static func artistRoute(_ ref: NameId) -> Route {
        ref.isOnline ? .onlineArtist(id: ref.id, name: ref.name ?? "") : .artist(.artistStub(ref))
    }

    /// Album page for a song, library or online (Spotify albums only).
    var albumRoute: Route? {
        if let stub = albumStub { return .album(stub) }
        if isExternal, let albumId, albumId.hasPrefix("sp:") { return .onlineAlbum(id: albumId, name: album ?? "") }
        return nil
    }
}

// MARK: - Client

/// What the Sonalex server next to this Jellyfin offers. Sonalex works with any Jellyfin server;
/// the optional server (backend/, reached at the Jellyfin address + /sonalex) adds the Mix,
/// Connect and, if its owner turned them on, the online catalog and the Spotify sync. The app only
/// shows what's there. Remembered, so the right screens show at once, even offline.
@Observable
@MainActor
final class ServerFeatures {
    static let shared = ServerFeatures()

    /// The Sonalex server answers: Mix and Connect.
    private(set) var companion = false
    /// Search, play and save songs that aren't in the library.
    private(set) var online = false
    /// Playlists and favorites follow a Spotify account.
    private(set) var spotifySync = false

    private struct Health: Decodable {
        struct Features: Decodable { var online: Bool?; var spotifySync: Bool? }
        var ok: Bool
        var features: Features?
    }

    private static let key = "server.features"

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Bool] ?? [:]
        companion = saved["companion"] ?? false
        online = saved["online"] ?? false
        spotifySync = saved["spotifySync"] ?? false
    }

    /// Asks the server (at login, at launch). A network failure keeps what was known.
    func refresh() async {
        guard let s = SessionStore.shared.session, let url = URL(string: s.server + "/sonalex/api/health") else { return }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return }
        let health = (response as? HTTPURLResponse)?.statusCode == 200
            ? try? JSONDecoder().decode(Health.self, from: data) : nil
        companion = health?.ok == true
        // A server from before the modules existed had them all.
        online = companion && (health?.features.map { $0.online ?? false } ?? true)
        spotifySync = companion && (health?.features.map { $0.spotifySync ?? false } ?? true)
        UserDefaults.standard.set(["companion": companion, "online": online, "spotifySync": spotifySync], forKey: Self.key)
    }

    func reset() {
        companion = false
        online = false
        spotifySync = false
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

/// The Sonalex server, reached through the Jellyfin address at /sonalex (same port).
@MainActor
final class SonalexAPI {
    static let shared = SonalexAPI()

    private var searchCache: [String: OnlineSearch] = [:]
    private var artistTracksCache: [String: [OnlineTrack]] = [:]

    private var session: Session? { SessionStore.shared.session }
    private var base: String? { session.map { $0.server + "/sonalex" } }

    enum Failure: LocalizedError {
        case server(String)
        var errorDescription: String? {
            switch self { case .server(let m): m }
        }
    }

    private func request(_ path: String, query: [String: String] = [:], method: String = "GET",
                         body: [String: Any]? = nil, timeout: TimeInterval = 20) async throws -> Data {
        guard let s = session, let base, var c = URLComponents(string: base + path) else { throw APIError.notLoggedIn }
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw APIError.badURL }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(JellyfinClient.authHeader(token: s.token), forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch {
            Connectivity.shared.requestFailed()
            throw APIError.unreachable
        }
        let data = result.0
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw Failure.server(detail ?? "Sonalex server error (\(code)).")
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], timeout: TimeInterval = 20) async throws -> T {
        try JellyfinClient.decoder.decode(T.self, from: await request(path, query: query, timeout: timeout))
    }

    // MARK: Catalog

    func search(_ q: String) async throws -> OnlineSearch {
        let key = q.lowercased()
        if let hit = searchCache[key] { return hit }
        let r: OnlineSearch = try await get("/api/search", ["q": q, "limit": "20"])
        if searchCache.count > 200 { searchCache.removeAll() }  // every keystroke of a search lands here
        searchCache[key] = r
        return r
    }

    /// Mix: a piece of a song (with the transition from the previous one), rendered by the Pi.
    func mixSegment<T: Decodable>(_ query: [String: String]) async throws -> T {
        try await get("/api/mix/segment", query, timeout: 240)
    }

    /// The file of a Mix piece (a path returned by mixSegment).
    func mixStreamURL(_ path: String) -> URL? {
        guard let s = session, let base, var c = URLComponents(string: base + path) else { return nil }
        c.queryItems = [URLQueryItem(name: "ApiKey", value: s.token)]
        return c.url
    }

    /// The online (Spotify) id of a library album, if it exists there.
    func resolveAlbum(title: String, artist: String) async throws -> String? {
        struct R: Decodable { var id: String? }
        let r: R = try await get("/api/resolve/album", ["title": title, "artist": artist])
        return r.id
    }

    /// Who made a song (producers, writers, engineers, label…), from Genius via the Pi.
    func credits(title: String, artist: String) async throws -> SongCredits {
        try await get("/api/credits", ["title": title, "artist": artist], timeout: 30)
    }

    /// Artist of the day (from the library, public page) and one to discover, chosen by the Pi.
    func daily() async throws -> DailyPicks {
        try await get("/api/daily", timeout: 40)
    }

    /// An id as one URL path segment ("name:AC/DC" must not become two segments).
    private static func segment(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%|")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    func artist(_ id: String) async throws -> OnlineArtistPage {
        try await get("/api/artist/\(Self.segment(id))")
    }

    /// Every track of an artist (top tracks first), cached for the session.
    func artistTracks(_ id: String) async throws -> [OnlineTrack] {
        if let hit = artistTracksCache[id] { return hit }
        struct R: Decodable { var tracks: [OnlineTrack] }
        let r: R = try await get("/api/artist/\(Self.segment(id))/tracks", timeout: 60)
        artistTracksCache[id] = r.tracks
        return r.tracks
    }

    func album(_ id: String) async throws -> OnlineAlbumPage {
        try await get("/api/album/\(Self.segment(id))")
    }

    func playlist(_ id: String) async throws -> OnlinePlaylistPage {
        try await get("/api/playlist/\(id)", timeout: 40)
    }

    func lyrics(_ key: String) async throws -> [LyricLine]? {
        let r: LyricsResponse = try await get("/api/lyrics/\(key)")
        return (r.lyrics?.isEmpty ?? true) ? nil : r.lyrics
    }

    // MARK: Playback

    func streamURL(for key: String) -> URL? {
        guard let s = session, let base, var c = URLComponents(string: "\(base)/api/stream/\(key)") else { return nil }
        c.queryItems = [URLQueryItem(name: "ApiKey", value: s.token)]
        return c.url
    }

    /// Tells the Pi a playlist changed so it updates Spotify right away. Fire-and-forget: returns
    /// immediately, never fails the edit (the Pi also catches up every 5 min and at night).
    func syncPlaylist(_ jellyfinPlaylistId: String) {
        guard ServerFeatures.shared.spotifySync else { return }
        Task { _ = try? await request("/api/sync/playlist/\(jellyfinPlaylistId)", method: "POST", timeout: 10) }
    }

    /// Player debug events (see PlayerDiagnostics).
    func sendDiagnostics(_ events: [[String: Any]]) {
        guard ServerFeatures.shared.companion, !events.isEmpty, JSONSerialization.isValidJSONObject(events) else { return }
        Task { _ = try? await request("/api/debug/player", method: "POST", body: ["events": events], timeout: 10) }
    }

    /// Lets the Pi find and download the next songs before they're needed.
    func prepare(_ keys: [String]) {
        guard ServerFeatures.shared.online, !keys.isEmpty else { return }
        Task { _ = try? await request("/api/prepare", method: "POST", body: ["keys": keys]) }
    }

    /// Songs to play after `seed` (Last.fm + Deezer + your library), skipping `recent`.
    func radio(seed: Item, recent: [(title: String, artist: String)], limit: Int = 20) async throws -> [Item] {
        struct R: Decodable { var tracks: [OnlineTrack] }
        let body: [String: Any] = [
            "seed": ["title": seed.title, "artist": seed.firstArtist?.name ?? seed.artistLine, "key": seed.externalKey ?? ""],
            "recent": recent.map { ["title": $0.title, "artist": $0.artist] },
            "limit": limit,
        ]
        let data = try await request("/api/radio", method: "POST", body: body, timeout: 40)
        return try JellyfinClient.decoder.decode(R.self, from: data).tracks.map(\.item)
    }

    // MARK: Library

    /// Downloads an online song into the Jellyfin library (as a favorite and/or into a playlist).
    func save(_ key: String, favorite: Bool, playlistId: String? = nil) async throws -> Item {
        var body: [String: Any] = ["favorite": favorite]
        if let playlistId { body["playlistId"] = playlistId }
        struct R: Decodable { var jellyfin: Item }
        let data = try await request("/api/save/\(key)", method: "POST", body: body, timeout: 180)
        JellyfinClient.shared.invalidateCache()
        return try JellyfinClient.decoder.decode(R.self, from: data).jellyfin
    }
}
