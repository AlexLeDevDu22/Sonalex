import Observation
import SwiftUI
import UIKit

// MARK: - Images

/// Memory cache on top of URLCache (disk). Decodes off the main thread so scrolling stays smooth.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 400
        return c
    }()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    /// URLs that returned no image this session (e.g. artists without a Jellyfin photo).
    private var failed: Set<URL> = []

    func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if failed.contains(url) { return nil }
        if let task = inflight[url] { return await task.value }
        // .utility: byPreparingForDisplay hops to a default-QoS thread, a higher QoS here is a
        // priority inversion (Xcode warns about it).
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            // Cover of a downloaded song: from the device (instant, works offline).
            if let local = OfflineCovers.file(for: url), let data = try? Data(contentsOf: local),
               let image = UIImage(data: data) {
                return await image.byPreparingForDisplay() ?? image
            }
            guard let result = try? await URLSession.shared.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: result.0) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) } else { failed.insert(url) }
        return image
    }
}

// MARK: - Toast (Apple-style HUD)

@Observable
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    struct Toast: Equatable {
        let id = UUID()
        let message: String
        let systemImage: String
    }

    private(set) var toast: Toast?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String = "checkmark") {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(duration: 0.35)) { toast = Toast(message: message, systemImage: systemImage) }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
        }
    }

    func error(_ error: Error) {
        show(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
    }
}

// MARK: - Favorites

/// Local overrides so a star toggles instantly everywhere, before the server confirms.
@Observable
@MainActor
final class FavoritesStore {
    static let shared = FavoritesStore()

    private var overrides: [String: Bool] = [:]

    func isFavorite(_ item: Item) -> Bool {
        overrides[item.id] ?? item.isFavoriteOnServer
    }

    func toggle(_ item: Item) {
        if let key = item.externalKey {
            saveOnline(item, key: key)
            return
        }
        let newValue = !isFavorite(item)
        overrides[item.id] = newValue
        PlayerManager.shared.syncRemoteCommandState()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do {
                try await JellyfinClient.shared.setFavorite(item.id, newValue)
                ConnectManager.shared.sendFavorite(ids: [item.id], value: newValue)
            } catch {
                overrides[item.id] = !newValue
                ToastCenter.shared.error(error)
            }
        }
    }

    /// Favorite changed on another device (Musique Connect).
    func applyRemote(ids: [String], value: Bool) {
        for id in ids { overrides[id] = value }
        PlayerManager.shared.syncRemoteCommandState()
    }

    /// Liking an online song downloads it into the library (then it's a normal favorite).
    private func saveOnline(_ item: Item, key: String) {
        guard overrides[item.id] != true else { return }
        overrides[item.id] = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        ToastCenter.shared.show("Ajout à ta bibliothèque…", systemImage: "arrow.down.circle")
        Task {
            do {
                let saved = try await SonalexAPI.shared.save(key, favorite: true)
                overrides[saved.id] = true
                ConnectManager.shared.sendFavorite(ids: [saved.id, item.id], value: true)
                PlayerManager.shared.replaceTrack(key: key, with: saved)
                PlayerManager.shared.syncRemoteCommandState()
                ToastCenter.shared.show("Ajouté à tes favoris", systemImage: "star.fill")
            } catch {
                overrides[item.id] = nil
                ToastCenter.shared.error(error)
            }
        }
    }

    func reset() { overrides = [:] }
}

// MARK: - Environment for presented screens

extension View {
    /// Every shared store, applied *outside* the whole presented content (overlays included):
    /// sheets and full-screen covers don't reliably inherit them, notably on the Mac.
    func appEnvironment() -> some View {
        self
            .environment(SessionStore.shared)
            .environment(PlayerManager.shared)
            .environment(AppRouter.shared)
            .environment(FavoritesStore.shared)
            .environment(ToastCenter.shared)
            .environment(AmbilightClient.shared)
    }
}

// MARK: - Navigation

enum AppTab: Hashable {
    case home, new, library, lights, search
    /// The Mac window (sidebar layout) uses a single navigation stack.
    case mac
}

enum Route: Hashable {
    case album(Item)
    case artist(Item)
    case playlist(Item)
    case genre(Item)
    case playlists, artists, albums, songs, favorites, downloaded, genres
    case onlineArtist(id: String, name: String)
    case onlineAlbum(id: String, name: String)
    case onlinePlaylist(id: String, name: String)
}

@Observable
@MainActor
final class AppRouter {
    static let shared = AppRouter()

    var tab: AppTab = .home
    var paths: [AppTab: [Route]] = [:]
    /// Item whose tracks should be added to a playlist (drives the picker sheet).
    var addToPlaylist: Item?
    /// Song whose credits sheet is open.
    var credits: Item?

    func binding(for tab: AppTab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { newValue in
            // Written by NavigationStack itself (link tapped, back button, or reverting a push).
            NavDiagnostics.log("stackSetPath", ["tab": "\(tab)", "from": Self.describe(self.paths[tab] ?? []),
                                                "to": Self.describe(newValue)])
            self.paths[tab] = newValue
        })
    }

    var tabSelection: Binding<AppTab> {
        Binding(get: { self.tab }, set: { newTab in
            if newTab == self.tab { self.paths[newTab] = [] } // tap on the active tab pops to root
            self.tab = newTab
        })
    }

    static func describe(_ path: [Route]) -> String {
        path.map { route -> String in
            switch route {
            case .album(let i): "album:\(i.title)"
            case .artist(let i): "artist:\(i.title)"
            case .playlist(let i): "playlist:\(i.title)"
            case .genre(let i): "genre:\(i.title)"
            case .onlineArtist(_, let n): "onlineArtist:\(n)"
            case .onlineAlbum(_, let n): "onlineAlbum:\(n)"
            case .onlinePlaylist(_, let n): "onlinePlaylist:\(n)"
            default: "\(route)"
            }
        }.joined(separator: " > ")
    }

    /// Swaps the visible page for another one (library ↔ online version), without stacking.
    func replaceTop(_ route: Route) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            var path = paths[tab] ?? []
            if !path.isEmpty { path.removeLast() }
            path.append(route)
            paths[tab] = path
        }
    }

    /// Push a page on the visible tab, closing the Now Playing screen if needed.
    func open(_ route: Route) {
        NavDiagnostics.log("open", ["route": Self.describe([route]), "tab": "\(tab)",
                                    "path": Self.describe(paths[tab] ?? []),
                                    "showNowPlaying": PlayerManager.shared.showNowPlaying])
        defer {
            let after = Self.describe(paths[tab] ?? [])
            Task { @MainActor in
                // What the stack holds a moment later (a revert would show here).
                try? await Task.sleep(for: .milliseconds(600))
                NavDiagnostics.log("afterOpen", ["tab": "\(self.tab)", "pathRightAfter": after,
                                                 "pathNow": Self.describe(self.paths[self.tab] ?? [])])
            }
        }
        let player = PlayerManager.shared
        if player.showNowPlaying {
            player.showNowPlaying = false
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                self.paths[self.tab, default: []].append(route)
            }
        } else {
            paths[tab, default: []].append(route)
        }
    }
}
