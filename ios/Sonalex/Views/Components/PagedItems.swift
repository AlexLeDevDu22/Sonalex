import Observation
import SwiftUI

/// Loads a long `/Items` list page by page as the user scrolls.
@Observable
@MainActor
final class PagedItems {
    private(set) var items: [Item] = []
    private(set) var total: Int?
    private(set) var loading = false
    private(set) var loadedOnce = false

    var query: [String: String]
    /// Server-side filter (`searchTerm`); empty = no filter.
    var search = ""
    let cacheable: Bool
    private let pageSize = 100
    @ObservationIgnored private var generation = 0

    init(query: [String: String], cacheable: Bool = true) {
        self.query = query
        self.cacheable = cacheable
    }

    var hasMore: Bool { total.map { items.count < $0 } ?? !loadedOnce }

    private var fullQuery: [String: String] {
        var q = query
        if !search.isEmpty { q["searchTerm"] = search }
        return q
    }

    /// Reloads the first page (keeps showing the old items until it arrives).
    func reload() async {
        generation += 1
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        var q = fullQuery
        q["StartIndex"] = "0"
        q["Limit"] = "\(pageSize)"
        guard let page = try? await JellyfinClient.shared.page(q, cacheable: cacheable), gen == generation else { return }
        items = page.items
        total = page.totalRecordCount ?? page.items.count
        loadedOnce = true
    }

    /// Call from each row's `onAppear`: fetches the next page when nearing the end.
    func loadMore(after item: Item) {
        guard hasMore, !loading, loadedOnce,
              let i = items.lastIndex(where: { $0.id == item.id }), i >= items.count - 20 else { return }
        let gen = generation
        loading = true
        var q = fullQuery
        q["StartIndex"] = "\(items.count)"
        q["Limit"] = "\(pageSize)"
        Task {
            defer { if gen == generation { loading = false } }
            guard let page = try? await JellyfinClient.shared.page(q, cacheable: cacheable), gen == generation else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            if let t = page.totalRecordCount { total = t }
            if page.items.isEmpty { total = items.count }
        }
    }

    /// The whole list (for Play / Shuffle), served from cache after the first time.
    func all() async throws -> [Item] {
        if let total, items.count >= total { return items }
        return try await JellyfinClient.shared.items(fullQuery, cacheable: cacheable)
    }
}
