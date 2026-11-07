import Foundation

/// What you listened to and when, kept on the phone (last 2000 plays). Feeds the smart
/// shuffle and keeps recommendations from repeating songs.
@MainActor
final class ListeningHistory {
    static let shared = ListeningHistory()

    struct Play: Codable {
        let signature: String
        let title: String
        let artist: String
        let date: Date
    }

    private var plays: [Play] = []
    private var lastBySignature: [String: Date] = [:]
    private static let key = "jm.listeningHistory"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Play].self, from: data) {
            plays = saved
            for p in saved { lastBySignature[p.signature] = p.date }
        }
    }

    /// Same song whatever its source (library, Spotify, Deezer): normalized title + main artist.
    static func signature(_ item: Item) -> String {
        signature(title: item.title, artist: item.firstArtist?.name ?? item.artistLine)
    }

    static func signature(title: String, artist: String) -> String {
        func norm(_ s: String) -> String {
            var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if let cut = t.firstIndex(where: { $0 == "(" || $0 == "[" }) { t = String(t[..<cut]) }
            if let dash = t.range(of: " - ") { t = String(t[..<dash.lowerBound]) }
            return t.filter { $0.isLetter || $0.isNumber }
        }
        let main = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first ?? artist
        return norm(title) + "|" + norm(main)
    }

    private static let saveQueue = DispatchQueue(label: "musique.history.save", qos: .utility)

    func record(_ item: Item) {
        let sig = Self.signature(item)
        // Ignore the same song re-recorded within a minute (seek back, repeat-one…).
        if let last = lastBySignature[sig], Date().timeIntervalSince(last) < 60 { return }
        let play = Play(signature: sig, title: item.title, artist: item.firstArtist?.name ?? item.artistLine, date: Date())
        plays.append(play)
        lastBySignature[sig] = play.date
        if plays.count > 2000 { plays.removeFirst(plays.count - 2000) }
        // Up to 2000 plays to encode: off the main thread (it's on the path of every song start).
        let snapshot = plays, key = Self.key
        Self.saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    /// Most recent of: our own history, Jellyfin's "last played" for library songs.
    func lastPlayed(_ item: Item) -> Date? {
        let own = lastBySignature[Self.signature(item)]
        let server = item.userData?.lastPlayedDate.flatMap(Self.parseDate)
        switch (own, server) {
        case let (a?, b?): return max(a, b)
        default: return own ?? server
        }
    }

    /// The last `count` distinct songs heard, newest first (sent to the Pi to avoid repeats).
    func recent(_ count: Int) -> [(title: String, artist: String)] {
        var seen = Set<String>()
        var out: [(title: String, artist: String)] = []
        for p in plays.reversed() where seen.insert(p.signature).inserted {
            out.append((p.title, p.artist))
            if out.count >= count { break }
        }
        return out
    }

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ raw: String) -> Date? {
        // Jellyfin sends 7 fractional digits, which ISO8601DateFormatter refuses: trim to 3.
        var s = raw
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let fraction = s[s.index(after: dot)..<end].prefix(3)
            s = String(s[..<dot]) + "." + fraction + String(s[end...])
        }
        return isoFull.date(from: s) ?? ISO8601DateFormatter().date(from: raw)
    }
}

/// Shuffle that feels random but plays well: songs you haven't heard for a long time come
/// first more often, songs heard in the last hours go to the end, and the same artist is
/// spread out instead of playing back to back.
enum SmartShuffle {
    @MainActor
    static func order(_ entries: [QueueEntry]) -> [QueueEntry] {
        guard entries.count > 2 else { return entries.shuffled() }
        let history = ListeningHistory.shared
        let now = Date()

        // Weighted random order (Efraimidis–Spirakis): key = u^(1/weight), highest first.
        let keyed = entries.map { entry -> (QueueEntry, Double) in
            let weight: Double
            if let last = history.lastPlayed(entry.track) {
                let hours = now.timeIntervalSince(last) / 3600
                if hours < 3 {
                    weight = 0.02 // just heard: almost always at the end
                } else {
                    weight = 1 + min(hours / 24, 60) / 6 // up to ×11 after two months
                }
            } else {
                weight = 6 // never heard (or not for ages)
            }
            return (entry, pow(Double.random(in: 0.0001...1), 1 / weight))
        }
        var ordered = keyed.sorted { $0.1 > $1.1 }.map(\.0)

        // Spread artists: if a song has the same main artist as the previous one, swap in the
        // next song (within a few places) by someone else.
        func artist(_ e: QueueEntry) -> String {
            (e.track.firstArtist?.name ?? e.track.artistLine).lowercased()
        }
        if ordered.count > 3 {
            for i in 1..<ordered.count where artist(ordered[i]) == artist(ordered[i - 1]) {
                let limit = min(ordered.count, i + 6)
                if let j = (i + 1..<limit).first(where: { artist(ordered[$0]) != artist(ordered[i - 1]) }) {
                    ordered.swapAt(i, j)
                }
            }
        }
        return ordered
    }
}
