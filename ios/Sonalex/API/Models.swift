import Foundation

struct NameId: Codable, Hashable {
    var name: String?
    var id: String
}

struct UserData: Codable, Hashable {
    var isFavorite: Bool?
    var playCount: Int?
    var lastPlayedDate: String?
    var played: Bool?
}

/// A Jellyfin `BaseItemDto` (song, album, artist, playlist, genre…), trimmed to what the app uses.
struct Item: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var type: String?
    var album: String?
    var albumId: String?
    var albumArtist: String?
    var albumArtists: [NameId]?
    var artistItems: [NameId]?
    var albumPrimaryImageTag: String?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var runTimeTicks: Int64?
    var productionYear: Int?
    var premiereDate: String?
    var dateCreated: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var childCount: Int?
    var songCount: Int?
    var albumCount: Int?
    var genres: [String]?
    var overview: String?
    var userData: UserData?
    var playlistItemId: String?
    var container: String?
    var hasLyrics: Bool?
    /// Online (not downloaded) songs: cover URL and the Musique API key ("sp:…" / "dz:…").
    var externalArt: String? = nil
    var externalKey: String? = nil
}

struct ItemsResult: Decodable {
    var items: [Item]
    var totalRecordCount: Int?
}

struct LyricLine: Decodable, Hashable {
    var text: String?
    var start: Int64?
}

struct LyricsResponse: Decodable {
    var lyrics: [LyricLine]?
}

enum ItemKind {
    static let song = "Audio"
    static let album = "MusicAlbum"
    static let artist = "MusicArtist"
    static let playlist = "Playlist"
    static let genre = "MusicGenre"
}

extension Item {
    var title: String { name ?? "" }

    /// Streamed from the online catalog rather than played from Jellyfin.
    var isExternal: Bool { externalKey != nil }

    var isSong: Bool { type == ItemKind.song }
    var isAlbum: Bool { type == ItemKind.album }
    var isArtist: Bool { type == ItemKind.artist }
    var isPlaylist: Bool { type == ItemKind.playlist }

    /// "Artist A, Artist B" for songs, album artist for albums.
    var artistLine: String {
        if let names = artistItems?.compactMap(\.name), !names.isEmpty { return names.joined(separator: ", ") }
        if let a = albumArtist, !a.isEmpty { return a }
        if let names = albumArtists?.compactMap(\.name), !names.isEmpty { return names.joined(separator: ", ") }
        return ""
    }

    var albumArtistLine: String {
        if let a = albumArtist, !a.isEmpty { return a }
        return artistLine
    }

    var duration: TimeInterval { Double(runTimeTicks ?? 0) / 10_000_000 }

    var isFavoriteOnServer: Bool { userData?.isFavorite ?? false }

    var year: Int? {
        if let productionYear { return productionYear }
        if let premiereDate, let y = Int(premiereDate.prefix(4)) { return y }
        return nil
    }

    var firstArtist: NameId? { artistItems?.first ?? albumArtists?.first }
    var firstAlbumArtist: NameId? { albumArtists?.first ?? artistItems?.first }

    /// Lightweight album reference built from a song, enough to navigate to the album page.
    var albumStub: Item? {
        guard let albumId, !isExternal else { return nil }
        return Item(id: albumId, name: album, type: ItemKind.album, albumArtist: albumArtist,
                    albumArtists: albumArtists,
                    imageTags: albumPrimaryImageTag.map { ["Primary": $0] })
    }

    static func artistStub(_ ref: NameId) -> Item {
        Item(id: ref.id, name: ref.name, type: ItemKind.artist)
    }
}
