import SwiftUI

struct LibraryView: View {
    @State private var recent: [Item] = []

    private let entries: [(String, String, Route)] = [
        ("Playlists", "music.note.list", .playlists),
        ("Artistes", "music.microphone", .artists),
        ("Albums", "square.stack", .albums),
        ("Morceaux", "music.note", .songs),
        ("Favoris", "star", .favorites),
        ("Téléchargés", "arrow.down.circle", .downloaded),
        ("Genres", "guitars", .genres),
    ]

    var body: some View {
        // ScrollView rather than List: the album grid holds many links, which a List row can't host.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries, id: \.0) { title, icon, route in
                    NavigationLink(value: route) {
                        HStack(spacing: 14) {
                            Image(systemName: icon)
                                .font(.title3)
                                .foregroundStyle(Color.appAccent)
                                .frame(width: 30)
                            Text(title)
                                .font(.title3)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 44)
                }

                if !recent.isEmpty {
                    Text("Ajouts récents")
                        .font(.title2.bold())
                        .padding(.top, 28)
                        .padding(.bottom, 12)
                    AlbumGrid(items: recent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle("Bibliothèque")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ProfileMenu() } }
        .libraryTask {
            recent = (try? await JellyfinClient.shared.items(["IncludeItemTypes": "MusicAlbum", "SortBy": "DateCreated,SortName",
                                                              "SortOrder": "Descending", "Limit": "20"])) ?? recent
        }
    }
}

struct AlbumGrid: View {
    let items: [Item]
    var subtitle: ((Item) -> String)? = nil
    var onItemAppear: ((Item) -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)], spacing: 20) {
            ForEach(items) { item in
                ItemCard(item: item, width: nil, subtitle: subtitle?(item))
                    .onAppear { onItemAppear?(item) }
            }
        }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @State private var playlists: [Item] = []
    @State private var loading = true
    @State private var showNew = false
    @State private var newName = ""
    @State private var toDelete: Item? = nil

    var body: some View {
        List {
            Button { showNew = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 56, height: 56)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Nouvelle playlist…").foregroundStyle(Color.appAccent)
                }
            }
            ForEach(RecentSources.shared.sorted(playlists)) { pl in
                NavigationLink(value: Route.playlist(pl)) {
                    CollectionRow(item: pl, subtitle: pl.childCount.map(Format.songCount))
                }
                .contextMenu { ItemMenu(item: pl) }
                .swipeActions {
                    Button(role: .destructive) { toDelete = pl } label: { Label("Supprimer", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && playlists.isEmpty { ProgressView() } }
        .navigationTitle("Playlists")
        .libraryTask { await load() }
        .alert("Nouvelle playlist", isPresented: $showNew) {
            TextField("Titre", text: $newName)
            Button("Annuler", role: .cancel) { newName = "" }
            Button("Créer") { create() }
        }
        .confirmationDialog("Supprimer « \(toDelete?.title ?? "") » ?", isPresented: Binding(
            get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
            Button("Supprimer la playlist", role: .destructive) { delete() }
        }
    }

    private func load() async {
        playlists = (try? await JellyfinClient.shared.items(["IncludeItemTypes": "Playlist", "SortBy": "DateCreated,SortName", "SortOrder": "Descending"], cacheable: false))
            ?? playlists
        loading = false
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        Task {
            do {
                try await JellyfinClient.shared.createPlaylist(name: name, ids: [])
                ToastCenter.shared.show("Playlist créée", systemImage: "music.note.list")
                await load()
            } catch { ToastCenter.shared.error(error) }
        }
    }

    private func delete() {
        guard let pl = toDelete else { return }
        toDelete = nil
        Task {
            do {
                try await JellyfinClient.shared.deleteItem(pl.id)
                withAnimation { playlists.removeAll { $0.id == pl.id } }
            } catch { ToastCenter.shared.error(error) }
        }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @State private var artists: [Item] = []
    @State private var loading = true
    @State private var filter = ""

    private var sections: [(String, [Item])] {
        let list = filter.isEmpty ? artists : artists.filter { $0.title.localizedCaseInsensitiveContains(filter) }
        let groups = Dictionary(grouping: list) { item -> String in
            let first = item.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).prefix(1).uppercased()
            return first.first?.isLetter == true ? first : "#"
        }
        return groups.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(sections, id: \.0) { letter, items in
                Section(letter) {
                    ForEach(items) { artist in
                        NavigationLink(value: Route.artist(artist)) {
                            HStack(spacing: 14) {
                                ArtworkView(item: artist, points: 48, circle: true)
                                    .frame(width: 48, height: 48)
                                Text(artist.title).font(.body)
                            }
                        }
                        .contextMenu { ItemMenu(item: artist) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { if loading { ProgressView() } }
        .navigationTitle("Artistes")
        .searchable(text: $filter, prompt: "Rechercher dans les artistes")
        .libraryTask {
            artists = (try? await JellyfinClient.shared.albumArtists()) ?? artists
            loading = false
        }
    }
}

// MARK: - Albums

struct AlbumsView: View {
    enum Sort: String, CaseIterable {
        case title = "Titre", artist = "Artiste", recent = "Ajout récent", year = "Année"

        var query: [String: String] {
            switch self {
            case .title: ["SortBy": "SortName", "SortOrder": "Ascending"]
            case .artist: ["SortBy": "AlbumArtist,SortName", "SortOrder": "Ascending"]
            case .recent: ["SortBy": "DateCreated,SortName", "SortOrder": "Descending"]
            case .year: ["SortBy": "ProductionYear,PremiereDate,SortName", "SortOrder": "Descending"]
            }
        }
    }

    @AppStorage("albums.sort") private var sort: Sort = .recent
    @State private var pager = PagedItems(query: ["IncludeItemTypes": "MusicAlbum"])
    @State private var filter = ""

    var body: some View {
        ScrollView {
            AlbumGrid(items: pager.items, onItemAppear: { pager.loadMore(after: $0) })
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            if pager.hasMore && pager.loadedOnce {
                ProgressView().padding(.bottom, 20)
            }
        }
        .overlay { if !pager.loadedOnce { ProgressView() } }
        .navigationTitle("Albums")
        .searchable(text: $filter, prompt: "Rechercher dans les albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Trier par", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .task(id: "\(LibrarySync.shared.version)|\(sort.rawValue)|\(filter)") {
            if pager.search != filter {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            pager.query = ["IncludeItemTypes": "MusicAlbum"].merging(sort.query) { $1 }
            pager.search = filter
            await pager.reload()
        }
        .refreshable {
            LibrarySync.shared.refreshAll()
            await pager.reload()
        }
    }
}

// MARK: - Songs & favorites

struct SongsView: View {
    var body: some View {
        SongListView(title: "Morceaux", query: ["IncludeItemTypes": "Audio", "SortBy": "DateCreated,SortName", "SortOrder": "Descending"])
    }
}

struct FavoritesView: View {
    var body: some View {
        SongListView(title: "Favoris", query: ["IncludeItemTypes": "Audio", "Filters": "IsFavorite", "SortBy": "DateCreated,SortName", "SortOrder": "Descending"],
                     cacheable: false, emptyMessage: "Touche ☆ sur un morceau pour l’ajouter à tes favoris.")
    }
}

/// Songs kept on this device (by hand, automatically or after a full listen), newest first.
/// Works offline: the list comes from the device's own index.
struct DownloadedSongsView: View {
    @Environment(PlayerManager.self) private var player
    @State private var filter = ""
    @State private var showSettings = false
    private var store: OfflineStore { .shared }

    private var songs: [Item] {
        let all = store.songs
        guard !filter.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(filter) || $0.artistLine.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        let songs = songs
        List {
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PlayShuffleButtons(onPlay: { player.play(songs, shuffle: false, source: "Téléchargés", sourceId: "downloaded") },
                                       onShuffle: { player.play(songs, shuffle: true, source: "Téléchargés", sourceId: "downloaded") })
                    Text("\(Format.songCount(songs.count)) · \(ByteCountFormatter.string(fromByteCount: store.usedBytes, countStyle: .file))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            }
            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                TrackRow(track: song) { player.play(songs, startAt: i, source: "Téléchargés", sourceId: "downloaded") }
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
                    .swipeActions {
                        Button(role: .destructive) { store.remove([song]) } label: {
                            Label("Retirer", systemImage: "trash")
                        }
                    }
            }
            if !store.downloading.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(store.downloading.count) en cours de téléchargement…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if songs.isEmpty && store.downloading.isEmpty {
                if filter.isEmpty {
                    ContentUnavailableView("Téléchargés", systemImage: "arrow.down.circle",
                                           description: Text("Télécharge un son, un album ou une playlist depuis son menu « … ». Tes favoris les plus écoutés arrivent ici tout seuls."))
                } else {
                    ContentUnavailableView.search(text: filter)
                }
            }
        }
        .navigationTitle("Téléchargés")
        .searchable(text: $filter, prompt: "Rechercher")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Réglages des téléchargements")
            }
        }
        .sheet(isPresented: $showSettings) { DownloadsSettingsView().appEnvironment() }
        .task { await store.fillMissingItems() }
    }
}

struct SongListView: View {
    let title: String
    var emptyMessage = "Aucun morceau."

    @Environment(PlayerManager.self) private var player
    @State private var pager: PagedItems
    @State private var filter = ""

    init(title: String, query: [String: String], cacheable: Bool = true, emptyMessage: String = "Aucun morceau.") {
        self.title = title
        self.emptyMessage = emptyMessage
        _pager = State(initialValue: PagedItems(query: query, cacheable: cacheable))
    }

    var body: some View {
        List {
            if !pager.items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PlayShuffleButtons(onPlay: { playAll(shuffle: false) }, onShuffle: { playAll(shuffle: true) })
                    if let total = pager.total {
                        Text(Format.songCount(total))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            }
            ForEach(pager.items) { song in
                TrackRow(track: song) { play(from: song) }
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
                    .onAppear { pager.loadMore(after: song) }
            }
            if pager.hasMore && pager.loadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if !pager.loadedOnce {
                ProgressView()
            } else if pager.items.isEmpty {
                if filter.isEmpty {
                    ContentUnavailableView(title, systemImage: "music.note", description: Text(emptyMessage))
                } else {
                    ContentUnavailableView.search(text: filter)
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $filter, prompt: "Rechercher")
        .task(id: "\(LibrarySync.shared.version)|\(filter)") {
            if pager.search != filter {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            pager.search = filter
            await pager.reload()
        }
        .refreshable {
            LibrarySync.shared.refreshAll()
            await pager.reload()
        }
    }

    private func playAll(shuffle: Bool) {
        Task {
            do {
                player.play(try await pager.all(), shuffle: shuffle, source: title)
            } catch { ToastCenter.shared.error(error) }
        }
    }

    /// Plays the whole list starting at `song`, not just the pages loaded so far.
    private func play(from song: Item) {
        Task {
            let all = (try? await pager.all()) ?? pager.items
            player.play(all, startAt: all.firstIndex { $0.id == song.id } ?? 0, source: title)
        }
    }
}

// MARK: - Genres

struct GenresView: View {
    @State private var genres: [Item] = []

    var body: some View {
        ScrollView {
            GenreGrid(genres: genres).padding(20)
        }
        .overlay { if genres.isEmpty { ProgressView() } }
        .navigationTitle("Genres")
        .libraryTask { genres = (try? await JellyfinClient.shared.genres()) ?? genres }
    }
}

struct GenreView: View {
    let genre: Item
    @Environment(PlayerManager.self) private var player
    @State private var albums: [Item] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PlayShuffleButtons(onPlay: { play(shuffle: false) }, onShuffle: { play(shuffle: true) })
                AlbumGrid(items: albums)
            }
            .padding(20)
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle(genre.title)
        .libraryTask {
            albums = (try? await JellyfinClient.shared.items(["IncludeItemTypes": "MusicAlbum", "GenreIds": genre.id,
                                                              "SortBy": "SortName"])) ?? albums
            loading = false
        }
    }

    private func play(shuffle: Bool) {
        Task {
            do {
                let songs = try await JellyfinClient.shared.items(["IncludeItemTypes": "Audio", "GenreIds": genre.id,
                                                                   "SortBy": "Album,ParentIndexNumber,IndexNumber"])
                player.play(songs, shuffle: shuffle, source: genre.title, sourceId: genre.playbackSourceId)
            } catch { ToastCenter.shared.error(error) }
        }
    }
}
