import Foundation

/// Mixes and stations are built ahead of time, so tapping their card plays instantly.
/// Each time one is used, a fresh version is prepared in the background for the next tap.
@MainActor
final class MixStore {
    static let shared = MixStore()

    private var ready: [String: [Item]] = [:]
    private var building: [String: Task<[Item], Error>] = [:]

    static let favorites = "mix:favorites"
    static let discovery = "mix:discovery"
    static func station(_ artistId: String) -> String { "station:\(artistId)" }

    /// Tracks for a mix id ("mix:favorites", "mix:discovery", "station:<artistId>").
    func tracks(for id: String) async throws -> [Item] {
        defer { prepare(id) }
        if let hit = ready.removeValue(forKey: id) { return hit }
        if let running = building[id] {
            // Take it over: its result is ours, the next one gets prepared afresh.
            building[id] = nil
            return try await running.value
        }
        return try await Self.build(id)
    }

    /// Builds `id` in the background unless it's already ready or being built.
    func prepare(_ id: String) {
        guard ready[id] == nil, building[id] == nil else { return }
        let task = Task { try await Self.build(id) }
        building[id] = task
        Task {
            let tracks = try? await task.value
            // Only if nobody took this build over in the meantime.
            guard building[id] == task else { return }
            building[id] = nil
            if let tracks, !tracks.isEmpty { ready[id] = tracks }
        }
    }

    func reset() {
        ready.removeAll()
        building.values.forEach { $0.cancel() }
        building.removeAll()
    }

    private static func build(_ id: String) async throws -> [Item] {
        let api = JellyfinClient.shared
        switch id {
        case favorites:
            return try await api.items(["IncludeItemTypes": "Audio", "Filters": "IsFavorite"]).shuffled()
        case discovery:
            return try await api.items(["IncludeItemTypes": "Audio", "SortBy": "Random", "Limit": "100"], cacheable: false)
        default:
            guard id.hasPrefix("station:") else { return [] }
            return try await api.artistStation(String(id.dropFirst("station:".count)))
        }
    }
}
