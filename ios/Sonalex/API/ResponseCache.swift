import Foundation
import Observation

/// API responses kept in memory and on disk, so the library shows up instantly on launch.
/// Entries fetched before the last nightly backend update are still served, but revalidated
/// in the background (see `JellyfinClient.send`).
@MainActor
final class ResponseCache {
    static let shared = ResponseCache()

    struct Entry {
        let data: Data
        let date: Date
    }

    private var memory: [String: Entry] = [:]
    /// Key → fetch date of everything on disk, so targeted invalidation also reaches entries not loaded yet.
    private var index: [String: Date]
    private let dir: URL
    private let indexURL: URL

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("api", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            index = saved
        } else {
            index = [:]
        }
    }

    func get(_ key: String) -> Entry? {
        if let hit = memory[key] { return hit }
        guard let date = index[key], let data = try? Data(contentsOf: fileURL(key)) else { return nil }
        let entry = Entry(data: data, date: date)
        memory[key] = entry
        return entry
    }

    func set(_ key: String, _ data: Data) {
        let now = Date()
        memory[key] = Entry(data: data, date: now)
        index[key] = now
        let url = fileURL(key)
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
        saveIndex()
    }

    func removeAll() {
        memory.removeAll()
        index.removeAll()
        // Synchronous so a write issued right after can't be wiped by a late cleanup.
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Drops every entry whose URL contains `fragment` (e.g. "Playlist" after editing a playlist).
    func remove(matching fragment: String) {
        let doomed = index.keys.filter { $0.contains(fragment) }
        guard !doomed.isEmpty else { return }
        for key in doomed {
            memory[key] = nil
            index[key] = nil
            try? FileManager.default.removeItem(at: fileURL(key))
        }
        saveIndex()
    }

    private func saveIndex() {
        let snapshot = index
        let url = indexURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func fileURL(_ key: String) -> URL {
        // FNV-1a: stable, short file names derived from the request URL.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return dir.appendingPathComponent(String(hash, radix: 16) + ".json")
    }
}

/// Bumped when fresh library data arrives; screens using `.libraryTask` reload when it changes.
@Observable
@MainActor
final class LibrarySync {
    static let shared = LibrarySync()

    private(set) var version = 0
    @ObservationIgnored private var bumpTask: Task<Void, Never>?

    /// Pull-to-refresh: forget everything and reload visible screens from the server.
    func refreshAll() {
        ResponseCache.shared.removeAll()
        version += 1
    }

    /// Background revalidations finish one by one; reload screens once they settle.
    func scheduleBump() {
        bumpTask?.cancel()
        bumpTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            version += 1
        }
    }

    /// The backend updates the music every night at midnight: anything fetched before
    /// the last 00:30 is revalidated (so at least one check per day).
    nonisolated static func lastBoundary(now: Date = Date()) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = 0
        c.minute = 30
        let today = cal.date(from: c) ?? now
        return now >= today ? today : (cal.date(byAdding: .day, value: -1, to: today) ?? today)
    }
}
