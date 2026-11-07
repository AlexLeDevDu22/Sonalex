import SwiftUI

struct ArtistView: View {
    let artist: Item

    @Environment(PlayerManager.self) private var player
    @Environment(FavoritesStore.self) private var favorites
    @State private var info: Item? = nil
    @State private var top: [Item] = []
    @State private var albums: [Item] = []
    @State private var appearsOn: [Item] = []
    @State private var similar: [Item] = []
    @State private var loading = true
    @State private var showTitle = false

    private var current: Item { info ?? artist }
    private let heroHeight: CGFloat = 400

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                hero

                if loading {
                    LoadingView()
                }
                if !top.isEmpty {
                    SongGridShelf(title: "Top titres", songs: top, source: current.title)
                }
                if !albums.isEmpty {
                    Shelf("Albums") {
                        ForEach(albums) { ItemCard(item: $0, width: 170, subtitle: $0.year.map(String.init) ?? "") }
                    }
                }
                if !appearsOn.isEmpty {
                    Shelf("Apparaît sur") {
                        ForEach(appearsOn) { ItemCard(item: $0, width: 150) }
                    }
                }
                if !similar.isEmpty {
                    Shelf("Artistes similaires") {
                        ForEach(similar) { ArtistCircle(artist: $0, size: 120) }
                    }
                }
                if let overview = current.overview, !overview.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "À propos de \(current.title)")
                        Text(overview)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                            .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .artistHeroPage(showTitle: showTitle, title: current.title)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top > heroHeight - 100
        } action: { _, past in
            withAnimation(.easeInOut(duration: 0.2)) { showTitle = past }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                let fav = favorites.isFavorite(current)
                Button { favorites.toggle(current) } label: {
                    Image(systemName: fav ? "star.fill" : "star")
                        .contentTransition(.symbolEffect(.replace))
                }
                Menu { ItemMenu(item: current) } label: { Image(systemName: "ellipsis") }
            }
        }
        .libraryTask { await load() }
    }

    /// Header image with the artist name; Lecture / Aléatoire right below.
    private var hero: some View {
        VStack(spacing: 20) {
            ArtistHero(name: current.title, height: heroHeight) { heroImage }
            if ServerFeatures.shared.online {
                VersionSwitch(isOnline: false, other: .onlineArtist(id: "name:\(current.title)", name: current.title))
            }
            PlayShuffleButtons(onPlay: { playAll(shuffle: false) }, onShuffle: { playAll(shuffle: true) })
                .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private var heroImage: some View {
        ArtworkView(item: current, points: 420, cornerRadius: 0)
    }

    private func playAll(shuffle: Bool) {
        Task {
            do {
                let songs = try await JellyfinClient.shared.artistTracks(artist.id)
                player.play(songs, shuffle: shuffle, source: current.title, sourceId: artist.playbackSourceId)
            } catch { ToastCenter.shared.error(error) }
        }
    }

    private func load() async {
        let api = JellyfinClient.shared
        let id = artist.id
        async let i = try? api.item(id)
        async let t = try? api.items(["ArtistIds": id, "IncludeItemTypes": "Audio", "SortBy": "PlayCount,SortName",
                                      "SortOrder": "Descending", "Limit": "20"])
        async let a = try? api.items(["AlbumArtistIds": id, "IncludeItemTypes": "MusicAlbum",
                                      "SortBy": "ProductionYear,PremiereDate,SortName", "SortOrder": "Descending"])
        async let c = try? api.items(["ContributingArtistIds": id, "IncludeItemTypes": "MusicAlbum", "SortBy": "SortName"])
        async let s = try? api.similar(id)
        let (infoResult, topResult, albumsResult, contribResult, similarResult) = await (i, t, a, c, s)
        info = infoResult
        top = topResult ?? []
        albums = albumsResult ?? []
        let own = Set(albums.map(\.id))
        appearsOn = (contribResult ?? []).filter { !own.contains($0.id) }
        similar = (similarResult ?? []).filter(\.isArtist)
        loading = false
    }
}
