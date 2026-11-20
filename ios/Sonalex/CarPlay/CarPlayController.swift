#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import UIKit

/// Sonalex on the car screen. A tab bar — Recent, Playlists, Albums, Artists — plus Search and
/// a Favorites shortcut, all driving the same `PlayerManager` as the phone. Now Playing is the
/// system template, fed by `MPNowPlayingInfoCenter` (already filled by PlayerManager), with
/// shuffle / repeat buttons and an Up Next list.
///
/// CarPlay templates are strict: a few list levels, short lists, big tap targets, no free layout.
/// Everything here runs on the main actor (CarPlay calls its delegate on the main thread), and no
/// artwork or network work blocks the UI — lists appear at once and fill in as data arrives.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    // Tabs are kept so their sections can be refreshed as data loads.
    private let recentTemplate = CPListTemplate(title: "Recent", sections: [])
    private let playlistsTemplate = CPListTemplate(title: "Playlists", sections: [])
    private let albumsTemplate = CPListTemplate(title: "Albums", sections: [])
    private let artistsTemplate = CPListTemplate(title: "Artists", sections: [])

    // MARK: Scene lifecycle

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        recentTemplate.tabTitle = "Recent"
        recentTemplate.tabImage = UIImage(systemName: "clock")
        recentTemplate.trailingNavigationBarButtons = [searchButton()]

        playlistsTemplate.tabTitle = "Playlists"
        playlistsTemplate.tabImage = UIImage(systemName: "music.note.list")

        albumsTemplate.tabTitle = "Albums"
        albumsTemplate.tabImage = UIImage(systemName: "square.stack")

        artistsTemplate.tabTitle = "Artists"
        artistsTemplate.tabImage = UIImage(systemName: "music.mic")

        for t in [recentTemplate, playlistsTemplate, albumsTemplate, artistsTemplate] {
            t.emptyViewTitleVariants = ["Nothing here yet"]
            t.emptyViewSubtitleVariants = ["Sign in on your iPhone and play some music."]
        }

        let tabBar = CPTabBarTemplate(templates: [recentTemplate, playlistsTemplate, albumsTemplate, artistsTemplate])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        configureNowPlaying()
        loadAll()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        if self.interfaceController === interfaceController { self.interfaceController = nil }
    }

    // MARK: Data loading

    private func loadAll() {
        loadRecent()
        load(playlistsTemplate, query: ["IncludeItemTypes": "Playlist", "SortBy": "SortName", "SortOrder": "Ascending"],
             container: .playlist)
        load(albumsTemplate, query: ["IncludeItemTypes": "MusicAlbum", "SortBy": "SortName", "SortOrder": "Ascending",
                                     "Limit": "500"], container: .album)
        loadArtists()
    }

    /// Recent = a Favorites shortcut on top, then recently played songs (tap plays from there).
    private func loadRecent() {
        Task {
            let favorites = CPListItem(text: "Favorites", detailText: "Your favorite songs")
            favorites.setImage(UIImage(systemName: "heart.fill"))
            favorites.accessoryType = .disclosureIndicator
            favorites.handler = { [weak self] _, completion in
                self?.pushSongList(title: "Favorites",
                                   query: ["IncludeItemTypes": "Audio", "Filters": "IsFavorite",
                                           "SortBy": "SortName", "Limit": "300"])
                completion()
            }

            let recent = (try? await JellyfinClient.shared.items(
                ["IncludeItemTypes": "Audio", "Filters": "IsPlayed", "SortBy": "DatePlayed",
                 "SortOrder": "Descending", "Limit": "60"], cacheable: false)) ?? []
            let songItems = self.songListItems(recent)

            var sections = [CPListSection(items: [favorites])]
            if !songItems.isEmpty {
                sections.append(CPListSection(items: songItems, header: "Recently Played", sectionIndexTitle: nil))
            }
            self.recentTemplate.updateSections(sections)
        }
    }

    private enum Container { case playlist, album }

    /// A flat list of containers (playlists or albums) that drill into their tracks.
    private func load(_ template: CPListTemplate, query: [String: String], container: Container) {
        Task {
            let items = (try? await JellyfinClient.shared.items(query, cacheable: true)) ?? []
            let rows = items.map { item -> CPListItem in
                let subtitle = container == .album ? item.albumArtistLine : "\(item.childCount ?? 0) songs"
                let row = CPListItem(text: item.title, detailText: subtitle)
                row.accessoryType = .disclosureIndicator
                self.loadArtwork(for: item, into: row)
                row.handler = { [weak self] _, completion in
                    switch container {
                    case .playlist:
                        self?.pushTracks(title: item.title) { try await JellyfinClient.shared.playlistTracks(item.id) }
                    case .album:
                        self?.pushTracks(title: item.title) { try await JellyfinClient.shared.albumTracks(item.id) }
                    }
                    completion()
                }
                return row
            }
            template.updateSections([CPListSection(items: rows)])
        }
    }

    private func loadArtists() {
        Task {
            let artists = (try? await JellyfinClient.shared.albumArtists()) ?? []
            let rows = artists.map { artist -> CPListItem in
                let row = CPListItem(text: artist.title, detailText: nil)
                row.accessoryType = .disclosureIndicator
                self.loadArtwork(for: artist, into: row)
                row.handler = { [weak self] _, completion in
                    // The artist's songs; tapping one plays the artist from there.
                    self?.pushTracks(title: artist.title) { try await JellyfinClient.shared.artistTracks(artist.id) }
                    completion()
                }
                return row
            }
            self.artistsTemplate.updateSections([CPListSection(items: rows)])
        }
    }

    // MARK: Pushing song lists

    /// Push a list fetched by a query (favorites, a genre…).
    private func pushSongList(title: String, query: [String: String]) {
        pushTracks(title: title) { try await JellyfinClient.shared.items(query, cacheable: false) }
    }

    /// Push a list of tracks produced by `fetch`; each row plays the whole list from its position.
    private func pushTracks(title: String, fetch: @escaping () async throws -> [Item]) {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = ["No songs"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        Task {
            let tracks = (try? await fetch()) ?? []
            template.updateSections([CPListSection(items: self.songListItems(tracks))])
        }
    }

    /// Rows for a concrete list of songs: tap = play the list from that song, then show Now Playing.
    private func songListItems(_ tracks: [Item]) -> [CPListItem] {
        tracks.enumerated().map { index, song in
            let row = CPListItem(text: song.title, detailText: song.artistLine)
            loadArtwork(for: song, into: row)
            row.handler = { [weak self] _, completion in
                PlayerManager.shared.play(tracks, startAt: index, source: "CarPlay")
                self?.pushNowPlaying()
                completion()
            }
            return row
        }
    }

    // MARK: Now Playing

    private func pushNowPlaying() {
        guard let ic = interfaceController else { return }
        if ic.topTemplate !== CPNowPlayingTemplate.shared {
            ic.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    private func configureNowPlaying() {
        let np = CPNowPlayingTemplate.shared
        np.add(self)
        np.isUpNextButtonEnabled = true
        np.upNextTitle = "Queue"

        let shuffle = CPNowPlayingImageButton(image: symbol("shuffle")) { _ in
            PlayerManager.shared.toggleShuffle()
        }
        let repeatButton = CPNowPlayingImageButton(image: symbol("repeat")) { _ in
            PlayerManager.shared.cycleRepeat()
        }
        np.updateNowPlayingButtons([shuffle, repeatButton])
    }

    // MARK: Search

    private func searchButton() -> CPBarButton {
        CPBarButton(image: symbol("magnifyingglass")) { [weak self] _ in
            guard let self, let ic = self.interfaceController else { return }
            let search = CPSearchTemplate()
            search.delegate = self
            ic.pushTemplate(search, animated: true, completion: nil)
        }
    }

    // MARK: Helpers

    private func symbol(_ name: String) -> UIImage {
        UIImage(systemName: name) ?? UIImage()
    }

    /// Fetch the artwork and drop it on the row when it arrives (cached hit shows immediately).
    private func loadArtwork(for item: Item, into row: CPListItem) {
        guard let url = JellyfinClient.shared.artURL(item, points: 88) else { return }
        if let cached = ImageCache.shared.cached(url) {
            row.setImage(cached)
            return
        }
        Task {
            if let image = await ImageCache.shared.image(for: url) {
                row.setImage(image)
            }
        }
    }
}

// MARK: - Search

extension CarPlaySceneDelegate: CPSearchTemplateDelegate {
    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        let term = searchText.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { completionHandler([]); return }
        Task {
            let results = (try? await JellyfinClient.shared.search(term))?.songs ?? []
            let rows = results.prefix(24).map { song -> CPListItem in
                let row = CPListItem(text: song.title, detailText: song.artistLine)
                row.userInfo = song
                self.loadArtwork(for: song, into: row)
                return row
            }
            completionHandler(Array(rows))
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        if let song = item.userInfo as? Item {
            // One song from search: play it, then keep going with similar songs (like the app).
            PlayerManager.shared.play([song], source: "Search", autoplay: true)
            pushNowPlaying()
        }
        completionHandler()
    }
}

// MARK: - Up Next

extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let upcoming = Array(PlayerManager.shared.queue.dropFirst(PlayerManager.shared.index + 1))
        let tracks = upcoming.map(\.track)
        let template = CPListTemplate(title: "Queue", sections: [])
        template.emptyViewTitleVariants = ["Nothing up next"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        let rows = tracks.enumerated().map { offset, song -> CPListItem in
            let row = CPListItem(text: song.title, detailText: song.artistLine)
            loadArtwork(for: song, into: row)
            row.handler = { [weak self] _, completion in
                // Jump ahead to the tapped song in the current queue.
                PlayerManager.shared.play(tracks, startAt: offset, source: "CarPlay")
                self?.pushNowPlaying()
                completion()
            }
            return row
        }
        template.updateSections([CPListSection(items: rows)])
    }
}
#endif
