import SwiftUI

// MARK: - Cards

struct OnlineArtistCircle: View {
    let artist: OnlineArtist
    var size: CGFloat = 104
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            NavDiagnostics.log("tap.onlineArtist", ["artist": artist.name])
            router.open(.onlineArtist(id: artist.id, name: artist.name))
        } label: {
            VStack(spacing: 8) {
                ArtworkView(url: artist.image.flatMap(URL.init(string:)), circle: true, artistName: artist.name, points: size)
                    .frame(width: size, height: size)
                Text(artist.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct OnlineAlbumCard: View {
    let album: OnlineAlbum
    var width: CGFloat = 150
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            NavDiagnostics.log("tap.onlineAlbum", ["album": album.name])
            router.open(.onlineAlbum(id: album.id, name: album.name))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(url: album.image.flatMap(URL.init(string:)), cornerRadius: 8)
                    .frame(width: width, height: width)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                Text(album.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(PressableStyle())
    }

    private var subtitle: String {
        let kind = album.type == "single" ? ((album.totalTracks ?? 1) > 3 ? "EP" : "Single") : "Album"
        return [kind, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Online artist

/// An artist from the online catalog: downloaded songs play from the library, the others stream.
/// Playing from here only ever plays this artist.
struct OnlineArtistView: View {
    let artistId: String
    let name: String

    @Environment(PlayerManager.self) private var player
    @State private var page: OnlineArtistPage? = nil
    @State private var error: String? = nil
    @State private var showTitle = false
    @State private var starting = false
    @State private var localArtist: Item?

    private let heroHeight: CGFloat = 380

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                VersionSwitch(isOnline: true, other: localArtist.map { .artist($0) })
                if let page {
                    PlayShuffleButtons(onPlay: { playAll(shuffle: false) }, onShuffle: { playAll(shuffle: true) })
                        .padding(.horizontal, 20)
                        .disabled(starting)
                    if !page.top.isEmpty { topTracks(page.top) }
                    if !page.albums.isEmpty {
                        Shelf("Albums") { ForEach(page.albums) { OnlineAlbumCard(album: $0) } }
                    }
                    if !page.singles.isEmpty {
                        Shelf("Singles & EPs") { ForEach(page.singles) { OnlineAlbumCard(album: $0) } }
                    }
                } else if let error {
                    ContentUnavailableView("Artist Unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
                } else {
                    LoadingView()
                }
            }
            .padding(.bottom, 30)
        }
        .artistHeroPage(showTitle: showTitle, title: displayName)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top > heroHeight - 100
        } action: { _, past in
            withAnimation(.easeInOut(duration: 0.2)) { showTitle = past }
        }
        .task { await load() }
        .task(id: displayName) { localArtist = await NameMatch.libraryArtist(named: displayName) }
    }

    private var displayName: String { page?.artist.name ?? name }

    private var hero: some View {
        ArtistHero(name: displayName, height: heroHeight) {
            ArtworkView(url: page?.artist.image.flatMap(URL.init(string:)), cornerRadius: 0,
                        placeholder: "music.microphone", artistName: displayName, points: 420)
        }
    }

    private func topTracks(_ top: [OnlineTrack]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Popular Songs")
            // One column on a phone, two or three on a wide screen.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24)], spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.key) { i, track in
                    TrackRow(track: track.item, showArtist: false, showDownloaded: true) { play(top, from: i) }
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Divider().padding(.leading, 60) }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func load() async {
        do {
            page = try await SonalexAPI.shared.artist(artistId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Starts with the popular songs right away, then the rest of the artist's songs follow.
    private func play(_ top: [OnlineTrack], from index: Int) {
        player.play(top.map(\.item), startAt: index, source: displayName)
        appendRest(after: top, shuffled: false)
    }

    private func playAll(shuffle: Bool) {
        guard let page else { return }
        if !page.top.isEmpty {
            player.play(page.top.map(\.item), shuffle: shuffle, source: displayName)
            appendRest(after: page.top, shuffled: shuffle)
            return
        }
        starting = true
        Task {
            defer { starting = false }
            guard let all = try? await SonalexAPI.shared.artistTracks(artistId), !all.isEmpty else { return }
            player.play(all.map(\.item), shuffle: shuffle, source: displayName)
        }
    }

    private func appendRest(after top: [OnlineTrack], shuffled: Bool) {
        let known = Set(top.map(\.key))
        Task {
            guard let all = try? await SonalexAPI.shared.artistTracks(artistId) else { return }
            let rest = all.filter { !known.contains($0.key) }.map(\.item)
            // Only if the user is still listening to this artist.
            guard player.sourceName == displayName, !rest.isEmpty else { return }
            player.addToQueue(shuffled ? rest.shuffled() : rest)
        }
    }
}

// MARK: - Online album

/// An album from the online catalog. Playing from here plays this album only.
struct OnlineAlbumView: View {
    let albumId: String
    let name: String

    @Environment(PlayerManager.self) private var player
    @Environment(AppRouter.self) private var router
    @State private var page: OnlineAlbumPage? = nil
    @State private var error: String? = nil
    @State private var showTitle = false
    @State private var localAlbum: Item?

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

            if let page {
                let items = page.tracks.map(\.item)
                let albumArtist = page.album.artist ?? ""
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    TrackRow(track: item, leading: .number, showArtist: item.artistLine != albumArtist,
                             showDownloaded: true, number: i + 1) {
                        player.play(items, startAt: i, source: page.album.name)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 12))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 58 }
                }
                let total = items.reduce(0) { $0 + $1.duration }
                Text("\(Format.songCount(items.count)), \(Format.totalDuration(total))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))
            } else if let error {
                ContentUnavailableView("Album Unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
                    .listRowSeparator(.hidden)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(showTitle ? (page?.album.name ?? name) : "")
        .navigationBarTitleDisplayMode(.inline)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top > 380
        } action: { _, past in
            withAnimation(.easeInOut(duration: 0.2)) { showTitle = past }
        }
        .task {
            do { page = try await SonalexAPI.shared.album(albumId) } catch { self.error = error.localizedDescription }
        }
    }

    private var header: some View {
        DetailHeader {
            ArtworkView(url: page?.album.image.flatMap(URL.init(string:)), cornerRadius: 10)
        } info: {
            Text(page?.album.name ?? name)
                .font(.title2.bold())
            if let album = page?.album {
                Button {
                    if let id = album.artistId { router.open(.onlineArtist(id: id, name: album.artist ?? "")) }
                } label: {
                    Text(album.artist ?? "")
                        .font(.title2)
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                let kind = album.type == "single" ? "SINGLE" : "ALBUM"
                Text([kind, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            PlayShuffleButtons(onPlay: { playAll(shuffle: false) }, onShuffle: { playAll(shuffle: true) },
                                   ready: page != nil)
                .padding(.top, 16)
            VersionSwitch(isOnline: true, other: localAlbum.map { .album($0) })
                .padding(.top, 10)
                .task(id: page?.album.id) {
                    guard let album = page?.album else { return }
                    localAlbum = await NameMatch.libraryAlbum(title: album.name, artist: album.artist)
                }
        }
    }

    private func playAll(shuffle: Bool) {
        guard let page else { return }
        player.play(page.tracks.map(\.item), shuffle: shuffle, source: page.album.name)
    }
}

// MARK: - Online playlist

struct OnlinePlaylistCard: View {
    let playlist: OnlinePlaylist
    var width: CGFloat = 150
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button { router.open(.onlinePlaylist(id: playlist.id, name: playlist.name)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(url: playlist.image.flatMap(URL.init(string:)), cornerRadius: 8, placeholder: "music.note.list")
                    .frame(width: width, height: width)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                Text(playlist.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(playlist.owner ?? "Playlist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(PressableStyle())
    }
}

/// A public Spotify playlist. Playing from here plays this playlist only.
struct OnlinePlaylistView: View {
    let playlistId: String
    let name: String

    @Environment(PlayerManager.self) private var player
    @State private var page: OnlinePlaylistPage? = nil
    @State private var error: String? = nil
    @State private var showTitle = false

    var body: some View {
        List {
            DetailHeader {
                ArtworkView(url: page?.playlist.image.flatMap(URL.init(string:)), cornerRadius: 10, placeholder: "music.note.list")
            } info: {
                Text(page?.playlist.name ?? name)
                    .font(.title2.bold())
                Text(["Playlist", page?.playlist.owner].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                PlayShuffleButtons(onPlay: { playAll(shuffle: false) }, onShuffle: { playAll(shuffle: true) },
                                       ready: page != nil)
                    .padding(.top, 16)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())

            if let page {
                let items = page.tracks.map(\.item)
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    TrackRow(track: item, showDownloaded: true) {
                        player.play(items, startAt: i, source: page.playlist.name)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
                }
                let total = items.reduce(0) { $0 + $1.duration }
                Text("\(Format.songCount(items.count)), \(Format.totalDuration(total))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))
            } else if let error {
                ContentUnavailableView("Playlist Unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
                    .listRowSeparator(.hidden)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(showTitle ? (page?.playlist.name ?? name) : "")
        .navigationBarTitleDisplayMode(.inline)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top > 360
        } action: { _, past in
            withAnimation(.easeInOut(duration: 0.2)) { showTitle = past }
        }
        .task {
            do { page = try await SonalexAPI.shared.playlist(playlistId) } catch { self.error = error.localizedDescription }
        }
    }

    private func playAll(shuffle: Bool) {
        guard let page else { return }
        player.play(page.tracks.map(\.item), shuffle: shuffle, source: page.playlist.name)
    }
}
