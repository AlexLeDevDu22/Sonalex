import Foundation

/// Artist photos missing from Jellyfin are looked up on Deezer's public API (no key needed).
/// Results — including "not found" — are remembered on disk so each artist is searched once.
@MainActor
final class ArtistImages {
    static let shared = ArtistImages()

    /// Normalized artist name → Deezer 1000×1000 picture URL, or "" when Deezer has none.
    private var known: [String: String]
    private var inflight: [String: Task<String, Never>] = [:]
    private static let storeKey = "jm.deezerArtistPictures"

    private init() {
        known = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
    }

    func url(for name: String, points: CGFloat) async -> URL? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return nil }
        let picture: String
        if let hit = known[key] {
            picture = hit
        } else if let running = inflight[key] {
            picture = await running.value
        } else {
            let task = Task.detached(priority: .utility) { await Self.search(name) }
            inflight[key] = task
            picture = await task.value
            inflight[key] = nil
            known[key] = picture
            UserDefaults.standard.set(known, forKey: Self.storeKey)
        }
        guard !picture.isEmpty else { return nil }
        // Deezer serves any square size from the same path.
        let px = points * 3 > 500 ? 1000 : 500
        return URL(string: picture.replacingOccurrences(of: "1000x1000", with: "\(px)x\(px)"))
    }

    nonisolated private static func search(_ name: String) async -> String {
        var c = URLComponents(string: "https://api.deezer.com/search/artist")
        c?.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: "5")]
        guard let url = c?.url,
              let result = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let artists = json["data"] as? [[String: Any]] else { return "" }
        let wanted = normalize(name)
        // Only trust an exact (accent/case-insensitive) name match, never a "close enough" artist.
        guard let match = artists.first(where: { normalize($0["name"] as? String ?? "") == wanted }),
              let picture = match["picture_xl"] as? String,
              !picture.contains("/artist//") else { return "" } // Deezer's blank placeholder
        return picture
    }

    nonisolated static func normalize(_ name: String) -> String {
        var s = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if s.hasPrefix("the ") { s.removeFirst(4) }
        return s.filter { $0.isLetter || $0.isNumber }
    }
}
