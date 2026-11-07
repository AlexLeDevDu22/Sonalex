import SwiftUI

struct SearchView: View {
    enum Scope: String, CaseIterable {
        case all = "All", artists = "Artists", albums = "Albums", songs = "Songs", playlists = "Playlists"
    }

    @Environment(PlayerManager.self) private var player
    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var results = JellyfinClient.SearchResults()
    @State private var searching = false
    @State private var genres: [Item] = []
    @AppStorage("search.recent") private var recentRaw = ""
    /// "online" = the server's online catalog (streamed if not downloaded), "library" = Jellyfin only.
    @AppStorage("search.source") private var source = "online"
    @State private var online = OnlineSearch()
    @State private var onlineError: String? = nil
    @Environment(AppRouter.self) private var router

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                browse
            } else if searchesOnline {
                onlineResults
            } else {
                resultsList
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artists, albums, songs…")
        .searchScopes($source, activation: .onSearchPresentation) {
            // Without the online catalog on the server, the library is the only place to search.
            if ServerFeatures.shared.online {
                Text("Online").tag("online")
                Text("Library").tag("library")
            }
        }
        .onSubmit(of: .search) { remember(query) }
        .task(id: query + "|" + source) { await runSearch() }
        .task(id: LibrarySync.shared.version) { genres = (try? await JellyfinClient.shared.genres()) ?? genres }
    }

    // MARK: Browse (empty query)

    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Recent Searches").font(.title3.bold())
                            Spacer()
                            Button("Clear") { recentRaw = "" }.foregroundStyle(Color.appAccent)
                        }
                        .padding(.bottom, 6)
                        ForEach(recent, id: \.self) { term in
                            Button { query = term } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                    Text(term).foregroundStyle(Color.appAccent)
                                    Spacer()
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 20)
                }

                if !genres.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Browse Categories").font(.title2.bold())
                        GenreGrid(genres: genres)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: Results

    private var resultsList: some View {
        List {
            if results.isEmpty {
                if searching {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40).listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView.search(text: query)
                        .listRowSeparator(.hidden)
                }
            }

            if show(.artists), !results.artists.isEmpty {
                Section(header: sectionTitle("Artists")) {
                    ForEach(results.artists.prefix(scope == .all ? 5 : 50)) { artist in
                        NavigationLink(value: Route.artist(artist)) {
                            HStack(spacing: 14) {
                                ArtworkView(item: artist, points: 52, circle: true).frame(width: 52, height: 52)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artist.title)
                                    Text("Artist").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contextMenu { ItemMenu(item: artist) }
                        .simultaneousGesture(TapGesture().onEnded { remember(query) })
                    }
                }
            }

            if show(.songs), !results.songs.isEmpty {
                Section(header: sectionTitle("Songs")) {
                    let songs = Array(results.songs.prefix(scope == .all ? 8 : 60))
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                        TrackRow(track: song) {
                            remember(query)
                            player.play(songs, startAt: i, source: "Search")
                        }
                    }
                }
            }

            if show(.albums), !results.albums.isEmpty {
                Section(header: sectionTitle("Albums")) {
                    ForEach(results.albums.prefix(scope == .all ? 6 : 50)) { album in
                        NavigationLink(value: Route.album(album)) {
                            CollectionRow(item: album, subtitle: album.collectionSubtitle)
                        }
                        .contextMenu { ItemMenu(item: album) }
                    }
                }
            }

            if show(.playlists), !results.playlists.isEmpty {
                Section(header: sectionTitle("Playlists")) {
                    ForEach(results.playlists.prefix(scope == .all ? 5 : 50)) { pl in
                        NavigationLink(value: Route.playlist(pl)) {
                            CollectionRow(item: pl, subtitle: pl.collectionSubtitle)
                        }
                        .contextMenu { ItemMenu(item: pl) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: Online results (Spotify catalog, downloaded songs marked)

    private var onlineResults: some View {
        List {
            if online.isEmpty {
                if searching {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40).listRowSeparator(.hidden)
                } else if let onlineError {
                    ContentUnavailableView("Online Search Unavailable", systemImage: "wifi.exclamationmark",
                                           description: Text(onlineError))
                        .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView.search(text: query).listRowSeparator(.hidden)
                }
            }

            if let top = topArtist {
                Section(header: sectionTitle("Top Result")) {
                    Button { open(top) } label: {
                        HStack(spacing: 14) {
                            ArtworkView(url: top.image.flatMap(URL.init(string:)), circle: true)
                                .frame(width: 72, height: 72)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(top.name).font(.title3.weight(.semibold))
                                Text("Artist").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !online.tracks.isEmpty {
                Section(header: sectionTitle("Songs")) {
                    ForEach(online.tracks.prefix(12)) { track in
                        let item = track.item
                        TrackRow(track: item, showDownloaded: true) {
                            remember(query)
                            // A song picked from search: it plays, then recommendations follow, endlessly.
                            player.play([item], source: "Search", autoplay: true)
                        }
                    }
                }
            }

            if !online.artists.isEmpty {
                Section(header: sectionTitle("Artists")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(online.artists.prefix(12)) { OnlineArtistCircle(artist: $0) }
                        }
                        .padding(.horizontal, 20)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                    .listRowSeparator(.hidden)
                }
            }

            if let playlists = online.playlists, !playlists.isEmpty {
                Section(header: sectionTitle("Playlists")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(playlists.prefix(16)) { OnlinePlaylistCard(playlist: $0) }
                        }
                        .padding(.horizontal, 20)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                    .listRowSeparator(.hidden)
                }
            }

            if !online.albums.isEmpty {
                Section(header: sectionTitle("Albums")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(online.albums.prefix(16)) { OnlineAlbumCard(album: $0) }
                        }
                        .padding(.horizontal, 20)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    /// The first artist, when the query is basically their name.
    private var topArtist: OnlineArtist? {
        guard let a = online.artists.first else { return nil }
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
        let n = a.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return n.hasPrefix(q) || q.hasPrefix(n) ? a : nil
    }

    private func open(_ artist: OnlineArtist) {
        remember(query)
        router.open(.onlineArtist(id: artist.id, name: artist.name))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private func show(_ s: Scope) -> Bool { scope == .all || scope == s }

    private var searchesOnline: Bool { source == "online" && ServerFeatures.shared.online }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = .init()
            return
        }
        searching = true
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        if searchesOnline {
            do {
                let r = try await SonalexAPI.shared.search(term)
                guard !Task.isCancelled else { return }
                onlineError = nil
                withAnimation(.easeOut(duration: 0.15)) { online = r }
                // Results stayed on screen a moment: get the first online songs ready on the Pi,
                // so tapping one starts (almost) instantly.
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled {
                    SonalexAPI.shared.prepare(Array(r.tracks.filter { $0.jellyfin == nil }.prefix(2).map(\.key)))
                }
            } catch {
                guard !Task.isCancelled else { return }
                onlineError = error.localizedDescription
            }
            searching = false
            return
        }
        do {
            let r = try await JellyfinClient.shared.search(term)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { results = r }
        } catch {}
        searching = false
    }

    private func remember(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let list = [t] + recent.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        recentRaw = list.prefix(8).joined(separator: "\n")
    }
}
