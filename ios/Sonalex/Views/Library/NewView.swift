import SwiftUI

struct NewView: View {
    @State private var hero: [Item] = []
    @State private var albums: [Item] = []
    @State private var songs: [Item] = []
    @State private var artists: [Item] = []
    @State private var genres: [Item] = []
    @State private var loaded = false
    @State private var error: String? = nil

    var body: some View {
        ScrollView {
            if let error, !loaded {
                ErrorStateView(message: error) { await load() }.padding(.top, 80)
            } else if !loaded {
                LoadingView().padding(.top, 120)
            } else {
                LazyVStack(alignment: .leading, spacing: 34) {
                    heroCarousel
                    if !songs.isEmpty {
                        SongGridShelf(title: "Nouveaux morceaux", songs: songs, destination: .songs)
                    }
                    if !albums.isEmpty {
                        Shelf("Albums récents", destination: .albums) {
                            ForEach(albums) { ItemCard(item: $0) }
                        }
                    }
                    if !artists.isEmpty {
                        Shelf("Artistes à découvrir", destination: .artists) {
                            ForEach(artists) { ArtistCircle(artist: $0) }
                        }
                    }
                    if !genres.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Parcourir par genre", destination: .genres)
                            GenreGrid(genres: Array(genres.prefix(8)))
                                .padding(.horizontal, 20)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("Nouveautés")
        .libraryTask { await load() }
    }

    private var heroCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(hero) { album in
                    NavigationLink(value: Route.album(album)) {
                        HeroCard(album: album)
                    }
                    .buttonStyle(PressableStyle(scale: 0.98))
                    .containerRelativeFrame(.horizontal) { w, _ in w > 700 ? min(520, (w - 52) / 2) : w - 40 }
                    .contextMenu { ItemMenu(item: album) }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }

    private func load() async {
        let api = JellyfinClient.shared
        do {
            async let a = api.items(["IncludeItemTypes": "MusicAlbum", "SortBy": "DateCreated,SortName", "SortOrder": "Descending",
                                     "Limit": "30"])
            async let s = api.items(["IncludeItemTypes": "Audio", "SortBy": "DateCreated,SortName", "SortOrder": "Descending",
                                     "Limit": "24"])
            async let ar = api.albumArtists(["SortBy": "Random", "Limit": "14"])
            async let g = api.genres()
            let (albumsResult, songsResult, artistsResult, genresResult) = try await (a, s, ar, g)
            hero = Array(albumsResult.prefix(6))
            albums = Array(albumsResult.dropFirst(6))
            songs = songsResult
            artists = artistsResult
            genres = genresResult
            loaded = true
        } catch {
            if !loaded { self.error = error.localizedDescription }
        }
    }
}

private struct HeroCard: View {
    let album: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AJOUTÉ RÉCEMMENT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(album.title)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.albumArtistLine)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ZStack {
                ArtworkView(item: album, points: 120, cornerRadius: 0)
                    .scaleEffect(1.6)
                    .blur(radius: 28)
                    .allowsHitTesting(false)
                    .overlay(Color.black.opacity(0.15))
                ArtworkView(item: album, points: 200, cornerRadius: 8)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.vertical, 22)
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct GenreGrid: View {
    let genres: [Item]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(genres) { genre in
                NavigationLink(value: Route.genre(genre)) {
                    GenreTile(genre: genre)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

struct GenreTile: View {
    let genre: Item

    var body: some View {
        let color = TileColor.color(for: genre.title)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [color, color.mix(with: .black, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(.white.opacity(0.14))
                .rotationEffect(.degrees(18))
                .offset(x: 20, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            Text(genre.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(12)
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
