import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Play statistics (listened to the end / skipped)

/// How often each song is listened to the end and skipped: feeds the automatic downloads.
@MainActor
final class PlayStats {
    static let shared = PlayStats()

    private struct Counts: Codable { var completed = 0; var skipped = 0; var last = Date.distantPast }
    private var counts: [String: Counts]
    private static let key = "offline.playStats"

    private init() {
        counts = (UserDefaults.standard.data(forKey: Self.key))
            .flatMap { try? JSONDecoder().decode([String: Counts].self, from: $0) } ?? [:]
    }

    func completed(_ track: Item) { update(track) { $0.completed += 1; $0.last = Date() } }
    func skipped(_ track: Item) { update(track) { $0.skipped += 1 } }

    /// Listened often, rarely skipped (Jellyfin's play count counts too).
    func score(_ track: Item) -> Double {
        let c = counts[track.id] ?? Counts()
        let plays = Double(max(c.completed, track.userData?.playCount ?? 0))
        let skipRate = Double(c.skipped) / Double(max(1, c.completed + c.skipped))
        let recent = c.last > Date().addingTimeInterval(-30 * 86400) ? 2.0 : 0
        return plays * (1 - skipRate) - Double(c.skipped) + recent
    }

    func skipRate(_ track: Item) -> Double {
        let c = counts[track.id] ?? Counts()
        return Double(c.skipped) / Double(max(1, c.completed + c.skipped))
    }

    private func update(_ track: Item, _ change: (inout Counts) -> Void) {
        guard !track.isExternal else { return }
        var c = counts[track.id] ?? Counts()
        change(&c)
        counts[track.id] = c
        if let data = try? JSONEncoder().encode(counts) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - Favourite of the moment

/// The song you pick yourself the most lately (taps on a song, not what plays next on its own).
/// Recent picks weigh more (half-life ~5 days), so it changes with your phases.
@MainActor
@Observable
final class MomentFavorite {
    static let shared = MomentFavorite()

    private struct Picks: Codable { var item: Item; var dates: [Date] }
    @ObservationIgnored private var picks: [String: Picks]
    private(set) var current: Item?
    /// Times it was picked over the last 7 days.
    private(set) var weekCount = 0
    private static let key = "momentFavorite.picks"

    private init() {
        picks = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: Picks].self, from: $0) } ?? [:]
        recompute()
    }

    func picked(_ track: Item) {
        guard track.isSong || track.type == nil else { return }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        var p = picks[track.id] ?? Picks(item: track, dates: [])
        p.item = track
        p.dates = p.dates.filter { $0 > cutoff } + [Date()]
        picks[track.id] = p
        picks = picks.filter { $0.value.dates.contains { $0 > cutoff } }
        if let data = try? JSONEncoder().encode(picks) { UserDefaults.standard.set(data, forKey: Self.key) }
        recompute()
    }

    func isMoment(_ item: Item) -> Bool { current?.id == item.id }

    private func recompute() {
        let now = Date()
        func score(_ p: Picks) -> Double {
            p.dates.reduce(0) { $0 + pow(0.5, now.timeIntervalSince($1) / (5 * 86400)) }
        }
        // At least 3 picks over two weeks, and clearly ahead of the runner-up.
        let ranked = picks.values
            .filter { p in p.dates.filter { now.timeIntervalSince($0) < 14 * 86400 }.count >= 3 }
            .map { ($0, score($0)) }
            .sorted { $0.1 > $1.1 }
        if let best = ranked.first, best.1 >= 2.5, ranked.count < 2 || best.1 >= ranked[1].1 * 1.15 {
            if current?.id != best.0.item.id { current = best.0.item }
            weekCount = best.0.dates.filter { now.timeIntervalSince($0) < 7 * 86400 }.count
        } else if let cur = current, let p = picks[cur.id], let s = ranked.first(where: { $0.0.item.id == cur.id })?.1,
                  s >= 2.5, s >= (ranked.first?.1 ?? 0) * 0.9 {
            // Keeps its title while still near the top (no flip-flopping between two songs).
            weekCount = p.dates.filter { now.timeIntervalSince($0) < 7 * 86400 }.count
        } else {
            current = nil
            weekCount = 0
        }
    }
}

// MARK: - Recently played sources (playlists sorted by last listen)

@MainActor
@Observable
final class RecentSources {
    static let shared = RecentSources()
    private(set) var lastPlayed: [String: Date]
    private static let key = "recentSources"

    private init() {
        lastPlayed = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Date]) ?? [:]
    }

    func played(_ sourceId: String?) {
        guard let sourceId else { return }
        lastPlayed[sourceId] = Date()
        UserDefaults.standard.set(lastPlayed, forKey: Self.key)
    }

    /// Most recently listened first; never listened keep their order, after.
    func sorted(_ items: [Item]) -> [Item] {
        items.enumerated().sorted { a, b in
            let da = a.element.playbackSourceId.flatMap { lastPlayed[$0] }
            let db = b.element.playbackSourceId.flatMap { lastPlayed[$0] }
            switch (da, db) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

// MARK: - Songs on this device

/// Songs kept on this device (iPhone or Mac): downloaded by hand (a song, an album, a playlist
/// kept in sync), automatically (favourites listened to the most and rarely skipped, within a size
/// limit, on Wi-Fi), or kept after being listened to the end (no new download: the file was
/// recorded while it streamed). Played from here instantly, even offline.
@MainActor
@Observable
final class OfflineStore {
    static let shared = OfflineStore()

    struct Entry: Codable {
        var file: String
        var bytes: Int64
        var added: Date
        var manual: Bool
        var title: String
        /// The song itself, to list downloads even offline (missing in older indexes).
        var item: Item?
    }

    private(set) var entries: [String: Entry] = [:]   // Jellyfin item id → file
    private(set) var downloading: Set<String> = []
    private(set) var offlinePlaylists: Set<String>
    var autoEnabled: Bool {
        didSet { UserDefaults.standard.set(autoEnabled, forKey: "offline.auto"); if autoEnabled { Task { await autoSync() } } }
    }
    var limitGB: Double {
        didSet { UserDefaults.standard.set(limitGB, forKey: "offline.limitGB"); Task { await autoSync() } }
    }
    var usedBytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes } }

    @ObservationIgnored private var queue: [(Item, Bool)] = []
    @ObservationIgnored private var working = false
    @ObservationIgnored private let dir: URL

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: OfflineCovers.dir, withIntermediateDirectories: true)
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(noBackup)
        autoEnabled = UserDefaults.standard.object(forKey: "offline.auto") as? Bool ?? true
        limitGB = UserDefaults.standard.object(forKey: "offline.limitGB") as? Double ?? 2
        offlinePlaylists = Set(UserDefaults.standard.stringArray(forKey: "offline.playlists") ?? [])
        if let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.value.file).path) }
        }
    }

    // MARK: Lookup

    func isDownloaded(_ item: Item) -> Bool { !item.isExternal && entries[item.id] != nil }

    func localURL(for item: Item) -> URL? {
        guard let e = entries[item.id] else { return nil }
        return dir.appendingPathComponent(e.file)
    }

    func isOffline(playlist: Item) -> Bool { offlinePlaylists.contains(playlist.id) }

    /// Songs on this device, most recently added first. Older entries without the song
    /// are filled in from Jellyfin once.
    var songs: [Item] {
        entries.sorted { $0.value.added > $1.value.added }.compactMap(\.value.item)
    }

    func fillMissingItems() async {
        let missing = entries.filter { $0.value.item == nil }.map(\.key)
        if !missing.isEmpty {
            for chunk in stride(from: 0, to: missing.count, by: 100).map({ Array(missing[$0..<min($0 + 100, missing.count)]) }) {
                guard let items = try? await JellyfinClient.shared.items(["Ids": chunk.joined(separator: ","),
                                                                          "IncludeItemTypes": "Audio"], cacheable: false) else { break }
                for item in items where entries[item.id] != nil { entries[item.id]?.item = item }
            }
            save()
        }
        // Songs downloaded before covers were kept with them.
        for item in songs { await saveCover(item) }
    }

    /// The song's cover, kept with it (see OfflineCovers). Songs of an album share one file.
    private func saveCover(_ track: Item) async {
        guard let url = JellyfinClient.shared.artURL(track, points: 200), let dest = OfflineCovers.file(for: url),
              !FileManager.default.fileExists(atPath: dest.path),
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200, UIImage(data: result.0) != nil else { return }
        try? result.0.write(to: dest, options: .atomic)
    }

    /// Covers no song on this device uses any more.
    private func removeUnusedCovers() {
        let used = Set(entries.values.compactMap { $0.item.flatMap { JellyfinClient.shared.artURL($0, points: 200) }
            .flatMap(OfflineCovers.file(for:))?.lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: OfflineCovers.dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where !used.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: Manual downloads

    func download(_ items: [Item]) {
        let songs = items.filter { $0.isSong && !$0.isExternal && entries[$0.id] == nil }
        for song in songs where !queue.contains(where: { $0.0.id == song.id }) { queue.append((song, true)) }
        // Already here automatically: now kept for good.
        for item in items where entries[item.id]?.manual == false { entries[item.id]?.manual = true }
        save()
        if !songs.isEmpty { ToastCenter.shared.show("Téléchargement de \(Format.songCount(songs.count))…", systemImage: "arrow.down.circle") }
        work()
    }

    func remove(_ items: [Item]) { removeIds(items.map(\.id)) }

    private func removeIds(_ ids: [String]) {
        for id in ids {
            if let e = entries.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.file))
            }
        }
        save()
        removeUnusedCovers()
    }

    func setOffline(playlist: Item, _ on: Bool) {
        if on { offlinePlaylists.insert(playlist.id) } else { offlinePlaylists.remove(playlist.id) }
        UserDefaults.standard.set(Array(offlinePlaylists), forKey: "offline.playlists")
        Task {
            guard let tracks = try? await JellyfinClient.shared.tracks(for: playlist) else { return }
            if on { download(tracks) } else { remove(tracks.filter { entries[$0.id]?.manual == true && !inOtherOfflinePlaylist($0) }) }
        }
    }

    private var playlistTracks: [String: Set<String>] = [:]
    private func inOtherOfflinePlaylist(_ track: Item) -> Bool {
        playlistTracks.contains { offlinePlaylists.contains($0.key) && $0.value.contains(track.id) }
    }

    /// Offline playlists follow their changes (new songs downloaded).
    func syncPlaylists() async {
        for id in offlinePlaylists {
            guard let tracks = try? await JellyfinClient.shared.playlistTracks(id) else { continue }
            playlistTracks[id] = Set(tracks.map(\.id))
            download(tracks)
        }
    }

    func removeAll() {
        for e in entries.values { try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.file)) }
        entries = [:]
        removeUnusedCovers()
        offlinePlaylists = []
        UserDefaults.standard.set([String](), forKey: "offline.playlists")
        save()
    }

    // MARK: Automatic downloads

    private var limitBytes: Int64 { Int64(limitGB * 1_073_741_824) }

    /// Favourites, best score first (listened often, rarely skipped), as much as the limit holds.
    func autoSync() async {
        guard autoEnabled,
              let favs = try? await JellyfinClient.shared.items(["IncludeItemTypes": "Audio", "Filters": "IsFavorite",
                                                                 "Limit": "3000"], cacheable: false) else { return }
        let stats = PlayStats.shared
        let ranked = favs.filter { !$0.isExternal && stats.skipRate($0) < 0.5 }.sorted { stats.score($0) > stats.score($1) }
        let manualBytes = entries.values.filter(\.manual).reduce(0) { $0 + $1.bytes }
        var budget = limitBytes - manualBytes
        var wanted = Set<String>()
        for track in ranked {
            let size = entries[track.id]?.bytes ?? Int64(track.duration * 20_000)  // ≤ 160 kbit/s
            guard budget - size > 0 else { break }
            budget -= size
            wanted.insert(track.id)
        }
        // Automatic songs that fell out of the selection make room.
        removeIds(entries.filter { !$0.value.manual && !wanted.contains($0.key) }.map(\.key))
        for track in ranked where wanted.contains(track.id) && entries[track.id] == nil && !queue.contains(where: { $0.0.id == track.id }) {
            queue.append((track, false))
        }
        work()
    }

    /// A song was listened to the end: if it's a favourite worth keeping, keep the file recorded
    /// while it streamed (no new download).
    func listenedToEnd(_ track: Item) {
        PlayStats.shared.completed(track)
        guard autoEnabled, !track.isExternal, entries[track.id] == nil,
              FavoritesStore.shared.isFavorite(track), PlayStats.shared.skipRate(track) < 0.5,
              let cached = StreamCache.shared.completeFile(for: track.id) else { return }
        let size = (try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard usedBytes + size <= limitBytes else { return }
        let name = "\(track.id).\(cached.pathExtension)"
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        guard (try? FileManager.default.copyItem(at: cached, to: dir.appendingPathComponent(name))) != nil else { return }
        entries[track.id] = Entry(file: name, bytes: size, added: Date(), manual: false, title: track.title, item: track)
        save()
        Task { await saveCover(track) }
    }

    // MARK: Worker

    private func work() {
        guard !working, !queue.isEmpty else { return }
        working = true
        Task {
            while !queue.isEmpty {
                let (track, manual) = queue.removeFirst()
                guard entries[track.id] == nil else { continue }
                downloading.insert(track.id)
                await fetch(track, manual: manual)
                downloading.remove(track.id)
            }
            working = false
        }
    }

    private func fetch(_ track: Item, manual: Bool) async {
        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = manual  // automatic downloads: Wi-Fi only
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)
        // The original when it's already light (many are ~130 kbit/s), else compact AAC 160 kbit/s.
        var heavy = false
        if let original = JellyfinClient.shared.fileURL(for: track), track.duration > 0 {
            var head = URLRequest(url: original)
            head.httpMethod = "HEAD"
            if let (_, r) = try? await session.data(for: head), r.expectedContentLength > 0 {
                heavy = Double(r.expectedContentLength) * 8 / track.duration > 200_000
            }
        }
        let original: (URL?, String) = (JellyfinClient.shared.fileURL(for: track), "mp3")
        let compact: (URL?, String) = (JellyfinClient.shared.compactFileURL(for: track), "m4a")
        let candidates = heavy ? [compact, original] : [original]
        for (url, ext) in candidates {
            guard let url else { continue }
            do {
                let (tmp, response) = try await session.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let name = "\(track.id).\(ext)"
                let dest = dir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                guard size > 10_000 else { try? FileManager.default.removeItem(at: dest); continue }
                entries[track.id] = Entry(file: name, bytes: size, added: Date(), manual: manual, title: track.title, item: track)
                save()
                await saveCover(track)
                return
            } catch {
                continue
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
        }
    }
}

// MARK: - Covers of the songs on this device

/// Covers of the downloaded songs, saved next to them: lists, the player and the lock screen show
/// them instantly, even offline. ImageCache looks here before going to the network.
enum OfflineCovers {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Offline/Covers", isDirectory: true)

    /// One file per picture whatever size is asked: `…/Items/<id>/Images/Primary?tag=<tag>` →
    /// `<id>-<tag>.jpg` (a new cover on Jellyfin has a new tag, so it's fetched again).
    static func file(for url: URL) -> URL? {
        let parts = url.pathComponents
        guard let i = parts.lastIndex(of: "Items"), parts.count > i + 3,
              parts[i + 2] == "Images", parts[i + 3] == "Primary" else { return nil }
        let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "tag" }?.value ?? ""
        return dir.appendingPathComponent("\(parts[i + 1])-\(tag).jpg")
    }
}

// MARK: - Stream cache (what was just listened to)

/// Files recorded while they streamed (CachingLoader): replays start instantly, and a song
/// listened to the end can be kept offline without downloading it again. ~600 MB, oldest out.
@MainActor
final class StreamCache {
    static let shared = StreamCache()
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Stream", isDirectory: true)
    private var active: [String: CachingLoader] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func completeFile(for id: String) -> URL? {
        let url = dir.appendingPathComponent("\(id).mp3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Asset that plays `remote` and records it to the cache at the same time.
    func asset(for id: String, remote: URL) -> (AVURLAsset, CachingLoader) {
        let loader = active[id] ?? CachingLoader(remote: remote, part: dir.appendingPathComponent("\(id).part"),
                                                 done: dir.appendingPathComponent("\(id).mp3"))
        active[id] = loader
        loader.onFinish = { [weak self] in
            Task { @MainActor in
                self?.active[id] = nil
                self?.trim()
            }
        }
        return (loader.makeAsset(), loader)
    }

    private func trim() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let sorted = files.filter { $0.pathExtension == "mp3" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var total = 0
        for url in sorted {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if total > 600 << 20 { try? fm.removeItem(at: url) }
        }
    }
}

/// AVAssetResourceLoader delegate: downloads the file once, front to back, writing it to disk,
/// and answers AVPlayer's byte-range requests from what has arrived (a far seek gets its own
/// ranged request meanwhile). When the whole file is there it is moved to `done`.
final class CachingLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let remote: URL
    let part: URL
    let done: URL
    var onFinish: (() -> Void)?

    private let queue = DispatchQueue(label: "musique.cachingloader")
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var length: Int64?
    private var mime: String?
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var finished = false
    private var ranged: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(remote: URL, part: URL, done: URL) {
        self.remote = remote
        self.part = part
        self.done = done
        super.init()
        let q = OperationQueue()
        q.underlyingQueue = queue
        q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: q)
    }

    func makeAsset() -> AVURLAsset {
        var c = URLComponents(url: remote, resolvingAgainstBaseURL: false)!
        c.scheme = "musiquecache"
        let asset = AVURLAsset(url: c.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    private func start() {
        guard task == nil, !finished else { return }
        FileManager.default.createFile(atPath: part.path, contents: nil)
        handle = try? FileHandle(forWritingTo: part)
        task = session.dataTask(with: remote)
        task?.resume()
    }

    // AVPlayer asks for data.
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        pending.append(loadingRequest)
        start()
        serve()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
        ranged.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private func serve() {
        guard let length else { return }
        pending.removeAll { request in
            if let info = request.contentInformationRequest {
                info.contentLength = length
                info.isByteRangeAccessSupported = true
                info.contentType = UTType(mimeType: mime ?? "audio/mpeg")?.identifier ?? UTType.mp3.identifier
            }
            guard let data = request.dataRequest else { request.finishLoading(); return true }
            let start = data.currentOffset
            let end = data.requestsAllDataToEndOfResource ? length : data.requestedOffset + Int64(data.requestedLength)
            if start >= end { request.finishLoading(); return true }
            if start < received {
                let upto = min(end, received)
                if let reader = try? FileHandle(forReadingFrom: part) {
                    try? reader.seek(toOffset: UInt64(start))
                    if let chunk = try? reader.read(upToCount: Int(upto - start)), !chunk.isEmpty {
                        data.respond(with: chunk)
                    }
                    try? reader.close()
                }
                if upto >= end { request.finishLoading(); return true }
            } else if start > received + 1_000_000, ranged[ObjectIdentifier(request)] == nil {
                // Far seek: fetch that part directly while the recording carries on.
                var r = URLRequest(url: remote)
                r.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
                let t = session.dataTask(with: r)
                ranged[ObjectIdentifier(request)] = t
                t.taskDescription = "\(ObjectIdentifier(request).hashValue)"
                t.resume()
            }
            return false
        }
    }

    // URLSession.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if dataTask === task {
            length = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            mime = response.mimeType
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if dataTask === task {
            try? handle?.write(contentsOf: data)
            received += Int64(data.count)
            serve()
        } else if let entry = ranged.first(where: { $0.value === dataTask }),
                  let request = pending.first(where: { ObjectIdentifier($0) == entry.key }) {
            request.dataRequest?.respond(with: data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task === self.task {
            try? handle?.close()
            handle = nil
            if error == nil, let length, received == length {
                finished = true
                try? FileManager.default.removeItem(at: done)
                try? FileManager.default.moveItem(at: part, to: done)
            } else {
                try? FileManager.default.removeItem(at: part)
            }
            serve()
            onFinish?()
            session.finishTasksAndInvalidate()  // releases the delegate (this loader)
        } else if let entry = ranged.first(where: { $0.value === task }) {
            ranged.removeValue(forKey: entry.key)
            if let i = pending.firstIndex(where: { ObjectIdentifier($0) == entry.key }) {
                let request = pending.remove(at: i)
                if let error { request.finishLoading(with: error) } else { request.finishLoading() }
            }
        }
    }
}

// MARK: - Settings

struct DownloadsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: OfflineStore { .shared }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    Toggle("Téléchargement automatique", isOn: $store.autoEnabled)
                    Picker("Place maximale", selection: $store.limitGB) {
                        ForEach([1.0, 2, 5, 10, 20], id: \.self) { Text("\(Int($0)) Go").tag($0) }
                    }
                } footer: {
                    Text("Tes favoris que tu écoutes le plus et que tu passes rarement sont gardés sur cet appareil (en Wi-Fi), ainsi que ceux que tu écoutes jusqu’au bout — sans les retélécharger. Ils se lancent tout de suite, même hors connexion.")
                }
                Section("Sur cet appareil") {
                    LabeledContent("Sons", value: "\(store.entries.count)")
                    LabeledContent("Espace utilisé", value: ByteCountFormatter.string(fromByteCount: store.usedBytes, countStyle: .file))
                    if !store.downloading.isEmpty {
                        LabeledContent("En cours", value: "\(store.downloading.count)")
                    }
                    Button("Tout supprimer de cet appareil", role: .destructive) { store.removeAll() }
                }
            }
            .navigationTitle("Téléchargements")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}
