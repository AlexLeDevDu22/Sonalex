import SwiftUI

#if targetEnvironment(macCatalyst)
import UIKit

/// Mac window, laid out like Apple Music on macOS: sidebar on the left, player bar on top,
/// lyrics / queue in a panel on the right. Every page and the whole engine are the iPhone ones.
struct MacRootView: View {
    enum Section: Hashable {
        case home, new, lights, search
        case artists, albums, songs, favorites, downloaded, genres
        case playlist(Item)
    }

    enum Panel { case lyrics, queue }

    @Environment(PlayerManager.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(AmbilightClient.self) private var ambi

    @State private var selection: Section? = .home
    @State private var panel: Panel? = nil
    @State private var playlists: [Item] = []

    var body: some View {
        @Bindable var player = player

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                // Always on top, whatever the page: nothing below may draw over it or take its clicks.
                MacPlayerBar(panel: $panel)
                    .zIndex(1)
                Divider()
                    .zIndex(1)
                NavigationStack(path: router.binding(for: .mac)) {
                    page(selection ?? .home)
                        .navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
                .id(selection)
                .clipped()
                .overlay { AmbientGlowOverlay() }
            }
            .inspector(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })) {
                MacSidePanel(panel: $panel)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            }
        }
        .onChange(of: selection) { old, new in
            NavDiagnostics.log("sidebarSelection", ["from": "\(String(describing: old))".prefix(80).description,
                                                    "to": "\(String(describing: new))".prefix(80).description])
            router.paths[.mac] = []
        }
        .fullScreenCover(isPresented: $player.showNowPlaying) {
            NowPlayingView()
                .overlay { ToastOverlay() }
                .appEnvironment()
        }
        .addToPlaylistPresenter(inNowPlaying: false)
        .overlay { ToastOverlay() }
        .task {
            router.tab = .mac
            ambi.start()
            ConnectManager.shared.start()
            NowPlayingExport.shared.startListeningForCommands()
            MenuBarController.shared.start()
            configureWindow()
        }
        .task(id: LibrarySync.shared.version) {
            playlists = (try? await JellyfinClient.shared.items(
                ["IncludeItemTypes": "Playlist", "SortBy": "DateCreated,SortName", "SortOrder": "Descending"],
                cacheable: false)) ?? playlists
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            SwiftUI.Section {
                Label("Recherche", systemImage: "magnifyingglass").tag(Section.search)
                Label("Accueil", systemImage: "house").tag(Section.home)
                Label("Nouveautés", systemImage: "square.grid.2x2").tag(Section.new)
                if ambi.reachable {
                    Label("Lumières", systemImage: "lightbulb.led").tag(Section.lights)
                }
            }
            SwiftUI.Section("Bibliothèque") {
                Label("Artistes", systemImage: "music.microphone").tag(Section.artists)
                Label("Albums", systemImage: "square.stack").tag(Section.albums)
                Label("Morceaux", systemImage: "music.note").tag(Section.songs)
                Label("Favoris", systemImage: "star").tag(Section.favorites)
                Label("Téléchargés", systemImage: "arrow.down.circle").tag(Section.downloaded)
                Label("Genres", systemImage: "guitars").tag(Section.genres)
            }
            if !playlists.isEmpty {
                SwiftUI.Section("Playlists") {
                    ForEach(RecentSources.shared.sorted(playlists)) { pl in
                        Label(pl.title, systemImage: "music.note.list")
                            .lineLimit(1)
                            .tag(Section.playlist(pl))
                            .contextMenu { ItemMenu(item: pl) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sonalex")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
        }
    }

    @ViewBuilder private func page(_ section: Section) -> some View {
        switch section {
        case .home: HomeView()
        case .new: NewView()
        case .lights: LightsView()
        case .search: SearchView()
        case .artists: ArtistsView()
        case .albums: AlbumsView()
        case .songs: SongsView()
        case .favorites: FavoritesView()
        case .downloaded: DownloadedSongsView()
        case .genres: GenresView()
        case .playlist(let item): PlaylistView(playlist: item)
        }
    }

    private func configureWindow() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 980, height: 640)
            scene.titlebar?.titleVisibility = .hidden
        }
    }
}

// MARK: - Player bar (top of the window, like Apple Music on Mac)

struct MacPlayerBar: View {
    @Binding var panel: MacRootView.Panel?
    @Environment(PlayerManager.self) private var player

    var body: some View {
        HStack(spacing: 22) {
            transport
            MacNowPlayingLCD()
                .frame(maxWidth: 560)
            trailing
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
        .background(.bar)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.shuffle ? Color.appAccent : .secondary)
            }
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title3) }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.88))
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode != .off ? Color.appAccent : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(player.current == nil)
    }

    private var trailing: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.controlledVolume }, set: { player.setVolume($0) }), in: 0...1)
                .frame(width: 100)
                .tint(.secondary)
            DevicePickerButton(tint: .secondary)
            panelButton(.lyrics, systemImage: "quote.bubble")
            panelButton(.queue, systemImage: "list.bullet")
        }
    }

    private func panelButton(_ target: MacRootView.Panel, systemImage: String) -> some View {
        let active = panel == target
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { panel = active ? nil : target }
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(active ? Color.appAccent : .secondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.appAccent.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// The center "screen" of the player bar. The cover's colors drift behind it and a soft spectrum
/// rises from its bottom edge with the music (the song playing here, or the one on the device being
/// controlled); the cover beats with the bass. Hovering shows the times; like and download on the right.
struct MacNowPlayingLCD: View {
    @Environment(PlayerManager.self) private var player
    @State private var dragProgress: Double? = nil
    @State private var hovering = false
    @State private var palette = ArtworkPalette.fallback

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        let track = player.current
        let live = track != nil && player.isPlaying

        HStack(spacing: 0) {
            LCDArtwork(track: track, live: live, buffering: track != nil && player.isBuffering, glow: palette.average)
                .padding(.leading, 5)

            VStack(spacing: 2) {
                Text(track?.title ?? "Sonalex")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if ConnectManager.shared.isRemote {
                    RemotePlaybackBadge()
                } else {
                    Text(track.map { [$0.artistLine, $0.album ?? ""].filter { !$0.isEmpty }.joined(separator: " — ") } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                scrubber(track)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)

            if let track {
                LCDActions(track: track)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 56)
        .background { LCDBackground(palette: palette, live: live, hasTrack: track != nil) }
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(Color.primary.opacity(hovering && track != nil ? 0.16 : 0.08)))
        .shadow(color: palette.average.opacity(track != nil ? 0.35 : 0), radius: hovering ? 10 : 6, y: 2)
        // The whole song rectangle opens the big player (lyrics next to the artwork); the progress
        // bar and the buttons keep their own gestures, which win over this tap.
        .contentShape(Self.shape)
        .onTapGesture { if track != nil { player.showNowPlaying = true } }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .help(track != nil ? "Afficher les paroles en grand" : "")
        .task(id: track?.id) {
            let p = await ArtworkPalette.load(JellyfinClient.shared.artURL(track, points: 100))
            withAnimation(.easeInOut(duration: 0.8)) { palette = p }
        }
    }

    private func scrubber(_ track: Item?) -> some View {
        let duration = max(player.duration, 0.1)
        let progress = dragProgress ?? min(max(player.currentTime / duration, 0), 1)
        let showTimes = (hovering || dragProgress != nil) && track != nil
        return HStack(spacing: 8) {
            if showTimes {
                Text(Format.time(progress * duration))
                    .transition(.opacity)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [Color.primary.opacity(0.45), Color.primary.opacity(0.75)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progress)
                    if showTimes {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 8, height: 8)
                            .offset(x: geo.size.width * progress - 4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: showTimes ? 4 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in dragProgress = min(max(v.location.x / max(geo.size.width, 1), 0), 1) }
                        .onEnded { _ in
                            if let p = dragProgress { player.seek(to: p * duration) }
                            dragProgress = nil
                        }
                )
            }
            .frame(height: 10)
            if showTimes {
                Text("-" + Format.time(max(0, duration - progress * duration)))
                    .transition(.opacity)
            }
        }
        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .disabled(track == nil)
    }
}

/// The cover, beating gently with the bass, with a glow of its own color behind it.
private struct LCDArtwork: View {
    let track: Item?
    let live: Bool
    let buffering: Bool
    let glow: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { _ in
            let bass = live ? (AmbilightAudioSink.shared.bands(localDelay: EqualizerBars.outputDelay)?.first ?? 0) : 0
            ZStack {
                ArtworkView(item: track, points: 46, cornerRadius: 7)
                if buffering {
                    Color.black.opacity(0.35)
                    ProgressView().tint(.white).controlSize(.small)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(1 + 0.045 * bass)
            .shadow(color: glow.opacity(0.4 + 0.5 * bass), radius: 4 + 8 * bass)
            .animation(.easeOut(duration: 0.12), value: bass)
        }
        .scaleEffect(live || track == nil ? 1 : 0.94)
        .animation(.spring(duration: 0.4), value: live)
    }
}

/// Behind the text: the cover's colors drifting slowly, a glow that breathes with the bass and a
/// faint spectrum along the bottom edge. Still when paused.
private struct LCDBackground: View {
    let palette: ArtworkPalette
    let live: Bool
    let hasTrack: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let heard = live ? AmbilightAudioSink.shared.bands(localDelay: EqualizerBars.outputDelay) : nil
            let bands = heard?.count == 4 ? heard ?? [] : [0, 0, 0, 0]
            ZStack {
                Color.primary.opacity(0.04)
                if hasTrack {
                    MeshGradient(width: 3, height: 3, points: points(Float(t)), colors: palette.colors, smoothsColors: true)
                        .opacity(scheme == .dark ? 0.55 : 0.32)
                    // Bass: a light swelling from behind the cover.
                    RadialGradient(colors: [palette.average.opacity(0.25 + 0.55 * bands[0]), .clear],
                                   center: UnitPoint(x: 0.05, y: 0.5), startRadius: 0, endRadius: 140 + 90 * bands[0])
                        .blendMode(scheme == .dark ? .plusLighter : .normal)
                    spectrum(bands, t: t)
                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                }
            }
        }
    }

    private func spectrum(_ bands: [Double], t: Double) -> some View {
        Canvas { g, size in
            let n = 56
            let w = size.width / CGFloat(n)
            for i in 0..<n {
                // Bass on the left, treble on the right, each bar wobbling a little on its own.
                let x = Double(i) / Double(n - 1) * 3
                let lo = Int(x), hi = min(lo + 1, 3), f = x - Double(lo)
                let level = bands[lo] * (1 - f) + bands[hi] * f
                let wobble = 0.7 + 0.3 * sin(t * 4.3 + Double(i) * 1.37)
                let h = size.height * 0.75 * CGFloat(min(1, level * wobble))
                guard h > 0.5 else { continue }
                let rect = CGRect(x: CGFloat(i) * w + 0.75, y: size.height - h, width: max(1, w - 1.5), height: h)
                g.fill(Path(roundedRect: rect, cornerRadius: 1.2), with: .color(Color.primary.opacity(0.13)))
            }
        }
    }

    private func points(_ t: Float) -> [SIMD2<Float>] {
        func wave(_ speed: Float, _ phase: Float) -> Float { 0.5 + sin(t * speed + phase) * 0.22 }
        return [SIMD2(0, 0), SIMD2(wave(0.5, 0), 0), SIMD2(1, 0),
                SIMD2(0, wave(0.45, 1)), SIMD2(wave(0.6, 2), wave(0.5, 3)), SIMD2(1, wave(0.4, 4)),
                SIMD2(0, 1), SIMD2(wave(0.55, 5), 1), SIMD2(1, 1)]
    }
}

/// Like and download, right in the song rectangle.
private struct LCDActions: View {
    let track: Item

    var body: some View {
        let favorites = FavoritesStore.shared
        let store = OfflineStore.shared
        let fav = favorites.isFavorite(track)
        let here = store.isDownloaded(track)
        let busy = store.downloading.contains(track.id)
        HStack(spacing: 2) {
            Button { favorites.toggle(track) } label: {
                Image(systemName: fav ? "star.fill" : "star")
                    .foregroundStyle(fav ? Color.appAccent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: fav)
            }
            .help(fav ? "Retirer des favoris" : "Ajouter aux favoris")

            Button { download(here: here) } label: {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: here ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(here ? Color.appAccent : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .disabled(busy)
            .help(here ? "Retirer de cet appareil" : "Télécharger sur cet appareil")
        }
        .buttonStyle(LCDButtonStyle())
        .font(.system(size: 14, weight: .semibold))
    }

    private func download(here: Bool) {
        let store = OfflineStore.shared
        if here { store.remove([track]); return }
        guard let key = track.externalKey else { store.download([track]); return }
        // Online song: into the library first (Jellyfin serves the file), then on this device.
        ToastCenter.shared.show("Ajout à ta bibliothèque…", systemImage: "arrow.down.circle")
        Task {
            do {
                let saved = try await SonalexAPI.shared.save(key, favorite: false)
                PlayerManager.shared.replaceTrack(key: key, with: saved)
                store.download([saved])
            } catch {
                ToastCenter.shared.error(error)
            }
        }
    }
}

/// Round highlight on hover, a little press: the buttons inside the song rectangle.
private struct LCDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.85 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Right panel: lyrics or queue over the artwork colors (like Apple Music's side panel).
struct MacSidePanel: View {
    @Binding var panel: MacRootView.Panel?
    @Environment(PlayerManager.self) private var player
    @State private var palette = ArtworkPalette.fallback

    var body: some View {
        ZStack {
            NowPlayingBackground(palette: palette)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(panel == .lyrics ? "Paroles" : "À suivre")
                        .font(.headline)
                    Spacer()
                    if panel == .lyrics {
                        // Lyrics in big: the full-window player shows them next to the artwork.
                        Button { player.showNowPlaying = true } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(0.15), in: Circle())
                        }
                        .help("Paroles en grand")
                        .disabled(player.current == nil)
                    }
                    Button { withAnimation(.easeInOut(duration: 0.25)) { panel = nil } } label: {
                        Image(systemName: "xmark")
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .keyboardShortcut(.cancelAction)
                    .help("Fermer")
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)

                Group {
                    if panel == .lyrics, let track = player.current {
                        LyricsView(track: track)
                    } else if panel == .lyrics {
                        Text("Aucune lecture en cours")
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        QueueView()
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .task(id: player.current?.id) {
            palette = await ArtworkPalette.load(JellyfinClient.shared.artURL(player.current, points: 200))
        }
    }
}
#endif

// MARK: - Keyboard shortcuts (Mac menu bar, and iPad keyboards)

struct PlaybackCommands: Commands {
    var body: some Commands {
        CommandMenu("Lecture") {
            Button("Lecture / Pause") { PlayerManager.shared.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Suivant") { PlayerManager.shared.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Précédent") { PlayerManager.shared.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Aléatoire") { PlayerManager.shared.toggleShuffle() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Répétition") { PlayerManager.shared.cycleRepeat() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("En lecture") { PlayerManager.shared.showNowPlaying = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
