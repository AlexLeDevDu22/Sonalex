import SwiftUI

/// Album / playlist tile: square artwork + two lines of text.
struct ItemCard: View {
    let item: Item
    var width: CGFloat? = 170
    var subtitle: String?

    @Environment(AppRouter.self) private var router
    @Environment(PlayerManager.self) private var player

    var body: some View {
        let active = player.isQueueSource(item)
        // A Button, not a NavigationLink: several links inside one List row all fire together.
        Button {
            NavDiagnostics.log("tap.itemCard", ["item": item.title, "hasRoute": item.route != nil])
            if let route = item.route { router.open(route) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(item: item, points: width ?? 180, cornerRadius: 8)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if active {
                            EqualizerBars(animating: player.isPlaying).scaleEffect(0.7).frame(width: 13, height: 10)
                        }
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(active ? Color.appAccent : .primary)
                            .lineLimit(1)
                    }
                    Text(subtitle ?? defaultSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu { ItemMenu(item: item) }
    }

    private var defaultSubtitle: String {
        if item.isPlaylist { return item.childCount.map(Format.songCount) ?? "Playlist" }
        return item.albumArtistLine
    }
}

struct ArtistCircle: View {
    let artist: Item
    var size: CGFloat = 110

    @Environment(AppRouter.self) private var router
    @Environment(PlayerManager.self) private var player

    var body: some View {
        let active = player.isQueueSource(artist)
        Button {
            NavDiagnostics.log("tap.artistCircle", ["artist": artist.title])
            router.open(.artist(artist))
        } label: {
            VStack(spacing: 8) {
                ArtworkView(item: artist, points: size, circle: true)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                Text(artist.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(active ? Color.appAccent : .primary)
                    .lineLimit(1)
            }
            .frame(width: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu { ItemMenu(item: artist) }
    }
}

/// Section title with optional "›" link, followed by a horizontally paging row.
struct Shelf<Content: View>: View {
    let title: String
    var destination: Route?
    @ViewBuilder let content: Content

    init(_ title: String, destination: Route? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.destination = destination
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, destination: destination)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content }
                    .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var destination: Route?

    var body: some View {
        Group {
            if let destination {
                NavigationLink(value: destination) {
                    HStack(spacing: 4) {
                        Text(title).font(.title2.bold()).foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.title2.bold())
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Apple Music "song grid": columns of 4 compact rows that page horizontally.
struct SongGridShelf: View {
    let title: String
    let songs: [Item]
    var destination: Route?
    var source: String?

    @Environment(PlayerManager.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, destination: destination)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(62), spacing: 0), count: min(4, max(songs.count, 1))),
                          spacing: 14) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                        SongCell(track: song) { player.play(songs, startAt: i, source: source ?? title) }
                            // One column on a phone, several ~360 pt columns on a wide screen.
                            .containerRelativeFrame(.horizontal) { w, _ in w > 700 ? 360 : w - 60 }
                            .overlay(alignment: .bottom) {
                                if i % 4 != 3 && i != songs.count - 1 {
                                    Divider().padding(.leading, 62)
                                }
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// The two big grey "Play" / "Shuffle" buttons of album & playlist pages.
///
/// Instant feedback: the tapped button shows a spinner and both are disabled until the song
/// actually plays. Tapped before the tracks are loaded (`ready == false`), it starts as soon as
/// they arrive instead of ignoring the tap.
struct PlayShuffleButtons: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var ready: Bool = true

    private enum Mode { case play, shuffle }
    @State private var pending: Mode?
    @State private var startedAt = Date.distantPast
    private var player: PlayerManager { .shared }

    var body: some View {
        HStack(spacing: 14) {
            button("Play", systemImage: "play.fill", mode: .play)
            button("Shuffle", systemImage: "shuffle", mode: .shuffle)
        }
        .disabled(pending != nil)
        .onChange(of: ready) { _, isReady in
            if isReady, pending != nil { fire() }
        }
        .onChange(of: player.isPlaying) { _, _ in clearIfStarted() }
        .onChange(of: player.isBuffering) { _, _ in clearIfStarted() }
        .task(id: startedAt) {
            // Never stay stuck: give the button back after a while whatever happens.
            guard pending != nil else { return }
            try? await Task.sleep(for: .seconds(12))
            pending = nil
        }
    }

    private func tap(_ mode: Mode) {
        guard pending == nil else { return }
        pending = mode
        startedAt = Date()
        if ready { fire() }
    }

    private func fire() {
        let mode = pending
        // Let SwiftUI draw the spinner first, then start the (heavier) queue setup.
        Task { @MainActor in
            await Task.yield()
            mode == .shuffle ? onShuffle() : onPlay()
        }
    }

    private func clearIfStarted() {
        guard pending != nil, Date().timeIntervalSince(startedAt) > 0.15 else { return }
        if player.isPlaying && !player.isBuffering { pending = nil }
    }

    private func button(_ title: String, systemImage: String, mode: Mode) -> some View {
        Button { tap(mode) } label: {
            HStack(spacing: 8) {
                if pending == mode {
                    ProgressView().tint(Color.appAccent)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(Color.appAccent)
            .opacity(pending != nil && pending != mode ? 0.45 : 1)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: pending)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
    }
}

struct LoadingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 300)
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        let offline = Connectivity.shared.isOffline
        ContentUnavailableView {
            Label(offline ? "No Connection" : "Couldn’t Load",
                  systemImage: offline ? "wifi.slash" : "wifi.exclamationmark")
        } description: {
            Text(offline ? "Your downloaded songs are still available on this device." : message)
        } actions: {
            if offline, !OfflineStore.shared.entries.isEmpty {
                NavigationLink(value: Route.downloaded) {
                    Label("Downloaded Songs", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }
            // Two different style types: a ternary between them doesn't compile.
            if offline {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.bordered)
            } else {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Album / playlist header: artwork above centered text on iPhone, artwork on the left with the
/// text beside it on wide screens (Mac, iPad), like Apple Music.
struct DetailHeader<Art: View, Info: View>: View {
    @ViewBuilder let art: Art
    @ViewBuilder let info: Info
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            HStack(alignment: .bottom, spacing: 28) {
                art
                    .frame(width: 240, height: 240)
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 6) { info }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 440, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 18)
        } else {
            VStack(spacing: 4) {
                art
                    .frame(width: 270, height: 270)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                info
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Artist page header. Phone: full-bleed photo with the name over it. Wide screen: the photo
/// as a square on the left (the whole face, not a thin middle strip) over a blurred backdrop.
/// The photo never takes taps (scaled-to-fill images spill past their frame and would swallow
/// the taps of whatever lies below).
struct ArtistHero<Art: View>: View {
    let name: String
    var height: CGFloat = 380
    @ViewBuilder let art: Art

    var body: some View {
        #if targetEnvironment(macCatalyst)
        // Mac: a plain header, no geometry tricks. The stretchy version (GeometryReader + offset)
        // slid over the player bar and the page on Catalyst, eating every click below it.
        HStack(alignment: .bottom, spacing: 28) {
            art
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .allowsHitTesting(false)
            Text(name)
                .font(.system(size: 44, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.bottom, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        GeometryReader { geo in
            let stretch = max(0, geo.frame(in: .scrollView).minY)
            let wide = geo.size.width > 700
            ZStack(alignment: .bottom) {
                if wide {
                    art
                        .frame(width: geo.size.width, height: height + stretch)
                        .blur(radius: 50)
                        .overlay(Color.black.opacity(0.35))
                        .clipped()
                        .allowsHitTesting(false)
                    HStack(alignment: .bottom, spacing: 28) {
                        art
                            .frame(width: 260, height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                            .allowsHitTesting(false)
                        Text(name)
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
                } else {
                    art
                        .frame(width: geo.size.width, height: height + stretch)
                        .clipped()
                        .allowsHitTesting(false)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)
                    Text(name)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.3), radius: 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
            }
            .frame(width: geo.size.width, height: height + stretch)
            .clipped()
            .offset(y: -stretch)
            .allowsHitTesting(false)
        }
        .frame(height: height)
        #endif
    }
}

extension View {
    /// Artist pages: on iPhone the photo goes up under a transparent navigation bar (Apple Music
    /// style). On the Mac it stays below the bar: ignoring the top safe area there made the page
    /// slide over the player bar and the transparent bar swallowed clicks on the page.
    @ViewBuilder
    func artistHeroPage(showTitle: Bool, title: String) -> some View {
        #if targetEnvironment(macCatalyst)
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        #else
        self
            .ignoresSafeArea(edges: .top)
            .navigationTitle(showTitle ? title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(showTitle ? .automatic : .hidden, for: .navigationBar)
        #endif
    }
}


// MARK: - Library / online versions of a page

/// "Ma bibliothèque | Tout" on artist and album pages that exist both in the library and online
/// (every song on Spotify, downloaded or not). Hidden when there is no other version.
struct VersionSwitch: View {
    let isOnline: Bool
    let other: Route?

    @Environment(AppRouter.self) private var router

    var body: some View {
        if let other {
            Picker("Version", selection: Binding(get: { isOnline }, set: { if $0 != isOnline { router.replaceTop(other) } })) {
                Text("My Library").tag(false)
                Text("All (online)").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum NameMatch {
    /// Case, accents and punctuation ignored; "(feat. …)" / "- Remastered" dropped.
    static func key(_ s: String?) -> String {
        var t = (s ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
        return t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// The library artist with this name, if any.
    @MainActor
    static func libraryArtist(named name: String) async -> Item? {
        guard let r = try? await JellyfinClient.shared.search(name) else { return nil }
        return r.artists.first { key($0.title) == key(name) }
    }

    /// The library album with this title by this artist, if any.
    @MainActor
    static func libraryAlbum(title: String, artist: String?) async -> Item? {
        guard let r = try? await JellyfinClient.shared.search(title) else { return nil }
        return r.albums.first { album in
            key(album.title) == key(title)
                && (artist == nil || key(album.albumArtistLine).contains(key(artist)) || key(artist).contains(key(album.albumArtistLine)))
        }
    }
}
