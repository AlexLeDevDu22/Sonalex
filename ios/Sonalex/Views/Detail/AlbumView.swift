import SwiftUI

struct AlbumView: View {
    let album: Item

    @Environment(PlayerManager.self) private var player
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AppRouter.self) private var router
    @State private var info: Item? = nil
    @State private var tracks: [Item] = []
    @State private var more: [Item] = []
    @State private var loading = true
    @State private var showTitle = false
    @State private var onlineAlbumId: String?

    private var current: Item { info ?? album }

    private var discs: [(Int, [Item])] {
        let groups = Dictionary(grouping: tracks) { $0.parentIndexNumber ?? 1 }
        return groups.keys.sorted().map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40).listRowSeparator(.hidden)
            }

            ForEach(discs, id: \.0) { disc, discTracks in
                Section {
                    ForEach(Array(discTracks.enumerated()), id: \.element.id) { position, track in
                        TrackRow(track: track, leading: .number,
                                 showArtist: track.artistLine != current.albumArtistLine, number: position + 1) {
                            let i = tracks.firstIndex(of: track) ?? 0
                            player.play(tracks, startAt: i, source: current.title, sourceId: album.playbackSourceId)
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 12))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 58 }
                    }
                } header: {
                    if discs.count > 1 {
                        Text("Disque \(disc)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }

            if !tracks.isEmpty {
                footer
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
            }

            if !more.isEmpty {
                Shelf("Plus de \(current.albumArtistLine)") {
                    ForEach(more) { ItemCard(item: $0, width: 150, subtitle: $0.year.map(String.init) ?? "") }
                }
                .padding(.vertical, 20)
                .background(Color(.secondarySystemBackground))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .navigationTitle(showTitle ? current.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top > 380
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
                Menu {
                    ItemMenu(item: current)
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .libraryTask { await load() }
    }

    private var header: some View {
        DetailHeader {
            ArtworkView(item: current, points: 270, cornerRadius: 10)
        } info: {
            Text(current.title)
                .font(.title2.bold())
            Button {
                if let a = current.firstAlbumArtist { router.open(.artist(.artistStub(a))) }
            } label: {
                Text(current.albumArtistLine)
                    .font(.title2)
                    .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
            let meta = [current.genres?.first?.uppercased(), current.year.map(String.init)].compactMap { $0 }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            PlayShuffleButtons(onPlay: { player.play(tracks, shuffle: false, source: current.title, sourceId: album.playbackSourceId) },
                               onShuffle: { player.play(tracks, shuffle: true, source: current.title, sourceId: album.playbackSourceId) },
                               ready: !tracks.isEmpty)
                .padding(.top, 16)
                .disabled(!loading && tracks.isEmpty)
            VersionSwitch(isOnline: false, other: onlineAlbumId.map { .onlineAlbum(id: $0, name: current.title) })
                .padding(.top, 10)
                .task(id: album.id) {
                    guard ServerFeatures.shared.online else { return }
                    onlineAlbumId = try? await SonalexAPI.shared.resolveAlbum(title: current.title,
                                                                              artist: current.albumArtistLine)
                }
        }
    }

    private var footer: some View {
        let total = tracks.reduce(0) { $0 + $1.duration }
        return VStack(alignment: .leading, spacing: 3) {
            if let date = Format.releaseDate(current) { Text(date) }
            Text("\(Format.songCount(tracks.count)), \(Format.totalDuration(total))")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func load() async {
        let api = JellyfinClient.shared
        async let i = try? api.item(album.id)
        async let t = try? api.albumTracks(album.id)
        let (itemResult, trackResult) = await (i, t)
        info = itemResult
        tracks = trackResult ?? []
        loading = false
        if let artistId = current.firstAlbumArtist?.id {
            let albums = (try? await api.items(["IncludeItemTypes": "MusicAlbum", "AlbumArtistIds": artistId,
                                                "SortBy": "ProductionYear,SortName", "SortOrder": "Descending"])) ?? []
            more = albums.filter { $0.id != album.id }
        }
    }
}
