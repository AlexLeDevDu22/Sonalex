import SwiftUI

@Observable
@MainActor
final class HomeModel {
    var recentAlbums: [Item] = []
    var mostPlayed: [Item] = []
    var playlists: [Item] = []
    var latest: [Item] = []
    var rediscover: [Item] = []
    var topArtists: [Item] = []
    var favoriteSample: [Item] = []
    /// Artist of the day / to discover (from the server; nil until it answers, or without the online catalog).
    var daily: DailyPicks?
    var loaded = false
    var error: String?

    func load() async {
        // In parallel, never holding Home back.
        if ServerFeatures.shared.online {
            Task { if let picks = try? await SonalexAPI.shared.daily() { daily = picks } }
        } else {
            daily = nil
        }
        let api = JellyfinClient.shared
        do {
            async let played = api.items(["IncludeItemTypes": "Audio", "SortBy": "DatePlayed", "SortOrder": "Descending",
                                          "Filters": "IsPlayed", "Limit": "200"])
            async let most = api.items(["IncludeItemTypes": "Audio", "SortBy": "PlayCount,SortName", "SortOrder": "Descending",
                                        "Filters": "IsPlayed", "Limit": "24"])
            async let lists = api.items(["IncludeItemTypes": "Playlist", "SortBy": "DateCreated", "SortOrder": "Descending", "Limit": "20"])
            async let newest = api.items(["IncludeItemTypes": "MusicAlbum", "SortBy": "DateCreated,SortName", "SortOrder": "Descending",
                                          "Limit": "20"])
            async let random = api.items(["IncludeItemTypes": "MusicAlbum", "SortBy": "Random", "Limit": "20"])
            async let favs = api.items(["IncludeItemTypes": "Audio", "Filters": "IsFavorite", "SortBy": "Random", "Limit": "12"])
            let (p, m, pl, n, r, f) = try await (played, most, lists, newest, random, favs)

            var seenAlbums = Set<String>()
            recentAlbums = p.compactMap { song in
                guard let album = song.albumStub, seenAlbums.insert(album.id).inserted else { return nil }
                return album
            }.prefix(16).map { $0 }

            var scores: [String: (ref: NameId, score: Int)] = [:]
            for song in p + m {
                for ref in song.artistItems ?? [] {
                    scores[ref.id, default: (ref, 0)].score += 1 + (song.userData?.playCount ?? 0)
                }
            }
            topArtists = scores.values.sorted { $0.score > $1.score }.prefix(12).map { Item.artistStub($0.ref) }

            mostPlayed = m
            playlists = pl
            latest = n
            rediscover = r
            favoriteSample = f
            loaded = true
            // Get every card's queue ready now, so a tap plays instantly.
            let mixes = MixStore.shared
            if !f.isEmpty { mixes.prepare(MixStore.favorites) }
            mixes.prepare(MixStore.discovery)
            for artist in topArtists.prefix(5) { mixes.prepare(MixStore.station(artist.id)) }
            error = nil
        } catch {
            if !loaded { self.error = error.localizedDescription }
        }
    }
}

struct HomeView: View {
    @State private var model = HomeModel()
    @Environment(PlayerManager.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            if let error = model.error, !model.loaded {
                ErrorStateView(message: error) { await model.load() }
                    .padding(.top, 80)
            } else if !model.loaded {
                LoadingView().padding(.top, 120)
            } else {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if let moment = MomentFavorite.shared.current {
                        MomentFavoriteCard(track: moment, count: MomentFavorite.shared.weekCount)
                    }
                    FriendsShelf()
                    if let daily = model.daily, daily.artist != nil {
                        DailyArtistsSection(picks: daily)
                    }
                    topPicks
                    if !model.recentAlbums.isEmpty {
                        Shelf("Recently Played") {
                            ForEach(model.recentAlbums) { ItemCard(item: $0) }
                        }
                    }
                    if !model.mostPlayed.isEmpty {
                        SongGridShelf(title: "Most Played", songs: model.mostPlayed)
                    }
                    if !model.playlists.isEmpty {
                        Shelf("Your Playlists", destination: .playlists) {
                            ForEach(RecentSources.shared.sorted(model.playlists)) { ItemCard(item: $0) }
                        }
                    }
                    if !model.topArtists.isEmpty {
                        Shelf("Your Artists") {
                            ForEach(model.topArtists) { ArtistCircle(artist: $0) }
                        }
                    }
                    if !model.latest.isEmpty {
                        Shelf("Recently Added", destination: .albums) {
                            ForEach(model.latest) { ItemCard(item: $0) }
                        }
                    }
                    if model.rediscover.count > 4 {
                        Shelf("Rediscover") {
                            ForEach(model.rediscover.dropFirst(4)) { ItemCard(item: $0) }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
        }
        .libraryTask { await model.load() }
    }

    @ViewBuilder private var topPicks: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Top Picks for You")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if !model.favoriteSample.isEmpty {
                        TopPickCard(caption: "Personal Mix", title: "Favorites Mix", subtitle: "Your favorite songs, shuffled",
                                    collage: model.favoriteSample, sourceId: "mix:favorites") { await playFavorites() }
                    }
                    ForEach(model.topArtists.prefix(5)) { artist in
                        TopPickCard(caption: "Station", title: "Station \(artist.title)",
                                    subtitle: "All of \(artist.title), even what you don’t have",
                                    artwork: artist, sourceId: "station:\(artist.id)") {
                            await playStation(artist)
                        }
                    }
                    TopPickCard(caption: "Personal Mix", title: "Discovery Mix", subtitle: "Random songs from your library",
                                collage: Array(model.rediscover.prefix(4)), sourceId: "mix:discovery") { await playDiscovery() }
                    ForEach(model.rediscover.prefix(4)) { album in
                        TopPickCard(caption: "Rediscover", title: album.title, subtitle: album.albumArtistLine,
                                    artwork: album, sourceId: "album:\(Self.publicAlbumId(album))") {
                            await playPublicAlbum(album)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private func playFavorites() async {
        do {
            let songs = try await MixStore.shared.tracks(for: MixStore.favorites)
            player.play(songs, shuffle: false, source: "Favorites Mix", sourceId: "mix:favorites")
        } catch { ToastCenter.shared.error(error) }
    }

    private func playDiscovery() async {
        do {
            let songs = try await MixStore.shared.tracks(for: MixStore.discovery)
            player.play(songs, shuffle: false, source: "Discovery Mix", sourceId: "mix:discovery")
        } catch { ToastCenter.shared.error(error) }
    }

    /// Discovery: the artist's public catalog (online songs stream), and their public page.
    private func playStation(_ artist: Item) async {
        let id = "name:\(artist.title)"
        router.open(.onlineArtist(id: id, name: artist.title))
        do {
            let tracks = try await SonalexAPI.shared.artistTracks(id)
            guard !tracks.isEmpty else { return }
            player.play(tracks.map(\.item), shuffle: true, source: "Station \(artist.title)", sourceId: "station:\(artist.id)")
        } catch { ToastCenter.shared.error(error) }
    }

    /// The public (Spotify) version of a library album: every track, downloaded or not.
    static func publicAlbumId(_ album: Item) -> String {
        "name:\(album.title)|\(album.firstAlbumArtist?.name ?? album.albumArtistLine)"
    }

    private func playPublicAlbum(_ album: Item) async {
        let id = Self.publicAlbumId(album)
        router.open(.onlineAlbum(id: id, name: album.title))
        do {
            let page = try await SonalexAPI.shared.album(id)
            guard !page.tracks.isEmpty else { return }
            player.play(page.tracks.map(\.item), shuffle: false, source: album.title, sourceId: "album:\(id)")
        } catch { ToastCenter.shared.error(error) }
    }
}

/// Tall "Top Picks" card: artwork on top, color band taken from the artwork below.
/// Playable cards (mixes, stations) play on a tap anywhere and show a visualizer while playing.
struct TopPickCard: View {
    let caption: String
    let title: String
    let subtitle: String
    var artwork: Item? = nil
    var collage: [Item] = []
    /// Set for playable cards: matches `PlayerManager.sourceId` of the queue it starts.
    var sourceId: String? = nil
    var action: (() async -> Void)? = nil

    @Environment(PlayerManager.self) private var player
    @State private var band: Color = Color(white: 0.25)
    @State private var starting = false
    private let width: CGFloat = 250

    private var isActive: Bool { sourceId != nil && player.sourceId == sourceId && player.current != nil }
    private var isPlaying: Bool { isActive && player.isPlaying }

    var body: some View {
        if action != nil {
            Button(action: tap) { card }
                .buttonStyle(PressableStyle(scale: 0.96))
                .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)
        } else {
            card
        }
    }

    private func tap() {
        if isActive {
            player.togglePlayPause()
            return
        }
        guard let action, !starting else { return }
        starting = true
        Task {
            await action()
            starting = false
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            ZStack {
                if !collage.isEmpty {
                    collageView
                } else {
                    ArtworkView(item: artwork, points: width, cornerRadius: 0, circle: false)
                }
                if action != nil { playOverlay }
            }
            .frame(width: width, height: width)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isActive {
                        EqualizerBars(animating: isPlaying, color: .white)
                            .scaleEffect(0.7, anchor: .leading)
                            .frame(width: 13, height: 10)
                    }
                    Text((isActive ? (isPlaying ? "Now Playing" : "Paused") : caption).uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.7))
                        .contentTransition(.opacity)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(14)
            .frame(width: width, alignment: .leading)
            .background(isActive ? Color.appAccent : band)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(isActive ? 0.55 : 0), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
        .animation(.easeInOut(duration: 0.25), value: isPlaying)
        .task(id: artwork?.id ?? collage.first?.id) {
            let source = artwork ?? collage.first
            let p = await ArtworkPalette.load(JellyfinClient.shared.artURL(source, points: 100))
            withAnimation { band = p.average }
        }
    }

    /// Big centered control over the whole artwork, so it reads as "tap the card to play".
    private var playOverlay: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(isActive ? 0.45 : 0.05), .black.opacity(isActive ? 0.55 : 0.3)],
                           startPoint: .top, endPoint: .bottom)
            Group {
                if starting {
                    ProgressView().tint(.white).controlSize(.large)
                } else if isPlaying {
                    EqualizerBars(animating: true, color: .white)
                        .scaleEffect(2.4)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                }
            }
            .frame(width: 76, height: 76)
            .background(.ultraThinMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .contentTransition(.symbolEffect(.replace))
        }
    }

    private var collageView: some View {
        let items = Array(collage.prefix(4))
        return Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                cell(items, 0)
                cell(items, 1)
            }
            GridRow {
                cell(items, 2)
                cell(items, 3)
            }
        }
    }

    private func cell(_ items: [Item], _ i: Int) -> some View {
        ArtworkView(item: items.isEmpty ? nil : items[i % items.count], points: width / 2, cornerRadius: 0)
            .frame(width: width / 2, height: width / 2)
    }
}

struct ProfileMenu: View {
    @Environment(SessionStore.self) private var session
    @State private var renaming = false
    @State private var deviceName = ""
    @State private var showDownloads = false
    @State private var showService = false
    @State private var community = Community.shared
    @Environment(AppRouter.self) private var router

    var body: some View {
        Menu {
            if let s = session.session {
                Section("\(s.userName) · \(s.serverName)") {
                    Button {
                        deviceName = ConnectManager.deviceName
                        renaming = true
                    } label: {
                        Label("Name of This Device…", systemImage: "pencil")
                    }
                    Button { showDownloads = true } label: {
                        Label("Downloads…", systemImage: "arrow.down.circle")
                    }
                    if ServerFeatures.shared.accounts {
                        Button { router.open(.friends) } label: {
                            Label("Friends", systemImage: "person.2")
                        }
                        if community.isAdmin {
                            Button { router.open(.accessRequests) } label: {
                                Label(community.requests.isEmpty ? "Access Requests" : "Access Requests (\(community.requests.count))",
                                      systemImage: "person.badge.clock")
                            }
                        }
                        if ServerFeatures.shared.spotifySync {
                            Button { showService = true } label: {
                                Label("Music Service…", systemImage: "music.note.list")
                            }
                        }
                    }
                    Button(role: .destructive) {
                        Task {
                            await JellyfinClient.shared.logoutRemote()
                            session.logout()
                        }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            Section("\(AppInfo.name) \(AppInfo.version)") {
                if !ServerFeatures.shared.companion {
                    Link(destination: AppInfo.serverGuide) {
                        Label("Add the Sonalex Server (Mix…)", systemImage: "wand.and.stars")
                    }
                }
                Link(destination: AppInfo.repository) {
                    Label("Project on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppInfo.privacyPolicy) {
                    Label("Privacy", systemImage: "hand.raised")
                }
            }
        } label: {
            Avatar(name: session.session?.userName ?? "?", size: 32)
                .overlay(alignment: .topTrailing) {
                    // Someone is waiting to join the server.
                    if community.isAdmin, !community.requests.isEmpty {
                        Circle().fill(.red).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .sheet(isPresented: $showDownloads) { DownloadsSettingsView() }
        .sheet(isPresented: $showService) { MusicServiceView().appEnvironment() }
        .alert("Name of This Device", isPresented: $renaming) {
            TextField(ConnectManager.defaultDeviceName, text: $deviceName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { ConnectManager.shared.rename(deviceName) }
        } message: {
            Text("The name your other devices (and Atoll) see when choosing where to play. Leave empty for the automatic name.")
        }
    }
}


// MARK: - Artiste du jour / À découvrir

/// Two big cards at the top of Home: today's artist (someone from your library, shown with their
/// full public page) and an artist of the same style you have nothing of. Picked by the server, the
/// same all day; only with the server's online catalog.
struct DailyArtistsSection: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerManager.self) private var player
    let picks: DailyPicks
    @State private var starting: String?

    var body: some View {
        Group {
            if let artist = picks.artist {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "For You Today")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            card(artist, caption: "ARTIST OF THE DAY",
                                 subtitle: artist.genres?.first.map { $0.capitalized } ?? "In your library")
                            if let discover = picks.discover {
                                card(discover, caption: "TO DISCOVER",
                                     subtitle: picks.because.map { "In the vein of \($0)" } ?? "New to you")
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, 20, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                }
            }
        }
    }

    private func card(_ artist: OnlineArtist, caption: String, subtitle: String) -> some View {
        Button { router.open(.onlineArtist(id: artist.id, name: artist.name)) } label: {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(url: artist.image.flatMap(URL.init(string:)), cornerRadius: 0,
                            placeholder: "music.microphone", artistName: artist.name, points: 340)
                    .frame(width: 300, height: 300)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(caption)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Color.appAccent)
                        Text(artist.name)
                            .font(.title.bold())
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Button { play(artist) } label: {
                        Group {
                            if starting == artist.id {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 18, weight: .bold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.appAccent, in: Circle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .disabled(starting != nil)
                }
                .padding(16)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
    }

    /// The artist's songs, downloaded or not (online ones stream).
    private func play(_ artist: OnlineArtist) {
        starting = artist.id
        Task {
            defer { starting = nil }
            do {
                let tracks = try await SonalexAPI.shared.artistTracks(artist.id)
                guard !tracks.isEmpty else { return }
                player.play(tracks.prefix(60).map(\.item), shuffle: false, source: artist.name)
            } catch { ToastCenter.shared.error(error) }
        }
    }
}

// MARK: - Favourite of the moment

/// The song you've been picking the most lately, put forward at the top of Home.
struct MomentFavoriteCard: View {
    let track: Item
    let count: Int
    @Environment(PlayerManager.self) private var player

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        Button {
            if isCurrent { player.togglePlayPause() }
            else { player.play([track], source: "Your Song of the Moment", autoplay: true) }
        } label: {
            HStack(spacing: 16) {
                ArtworkView(item: track, points: 110, cornerRadius: 10)
                    .frame(width: 110, height: 110)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Your Song of the Moment", systemImage: "flame.fill")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing))
                    Text(track.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(track.artistLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if count > 1 {
                        Text("Picked \(count) times this week")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [.orange.opacity(0.22), .pink.opacity(0.14), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.orange.opacity(0.25), lineWidth: 1))
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu { ItemMenu(item: track) }
        .padding(.horizontal, 20)
        .frame(maxWidth: 720, alignment: .leading)
    }
}
