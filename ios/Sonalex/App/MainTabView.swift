import SwiftUI

struct MainTabView: View {
    @Environment(PlayerManager.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(AmbilightClient.self) private var ambi
    @Namespace private var nowPlayingNamespace

    var body: some View {
        @Bindable var player = player

        TabView(selection: router.tabSelection) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                stack(.home) { HomeView() }
            }
            Tab("New", systemImage: "square.grid.2x2.fill", value: AppTab.new) {
                stack(.new) { NewView() }
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                stack(.library) { LibraryView() }
            }
            // Only when the Ambilight server on the Mac answers (or while you're on the page).
            if ambi.reachable || router.tab == .lights {
                Tab("Lights", systemImage: "lightbulb.led.fill", value: AppTab.lights) {
                    stack(.lights) { LightsView() }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                stack(.search) { SearchView() }
            }
        }
        .modifier(MiniPlayerPlacement(namespace: nowPlayingNamespace))
        .fullScreenCover(isPresented: $player.showNowPlaying) {
            NowPlayingView()
                .overlay { ToastOverlay() }
                .appEnvironment()
                .navigationTransition(.zoom(sourceID: "nowPlayingArtwork", in: nowPlayingNamespace))
        }
        .addToPlaylistPresenter(inNowPlaying: false)
        .overlay { ToastOverlay() }
        .task {
            ambi.start()
            ConnectManager.shared.start()
        }
    }

    private func stack<Content: View>(_ tab: AppTab, @ViewBuilder root: () -> Content) -> some View {
        NavigationStack(path: router.binding(for: tab)) {
            root()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        // Inside the tab's content, so the tab bar and the mini player stay drawn above the glow.
        .overlay { AmbientGlowOverlay() }
        .modifier(MiniPlayerInset())
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        content
            .onAppear { NavDiagnostics.log("pageAppear", ["page": AppRouter.describe([route])]) }
            .onDisappear { NavDiagnostics.log("pageDisappear", ["page": AppRouter.describe([route])]) }
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .album(let item): AlbumView(album: item)
        case .artist(let item): ArtistView(artist: item)
        case .playlist(let item): PlaylistView(playlist: item)
        case .genre(let item): GenreView(genre: item)
        case .playlists: PlaylistsView()
        case .artists: ArtistsView()
        case .albums: AlbumsView()
        case .songs: SongsView()
        case .favorites: FavoritesView()
        case .downloaded: DownloadedSongsView()
        case .genres: GenresView()
        case .onlineArtist(let id, let name): OnlineArtistView(artistId: id, name: name)
        case .onlineAlbum(let id, let name): OnlineAlbumView(albumId: id, name: name)
        case .onlinePlaylist(let id, let name): OnlinePlaylistView(playlistId: id, name: name)
        }
    }
}

/// iOS 26: native Liquid Glass accessory above the tab bar (exactly like Apple Music).
/// iOS 18: floating bar drawn above the tab bar.
private struct MiniPlayerPlacement: ViewModifier {
    let namespace: Namespace.ID
    @Environment(PlayerManager.self) private var player
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 26.1, *) {
            // Hidden while nothing is playing.
            content
                .tabViewBottomAccessory(isEnabled: player.current != nil) {
                    MiniPlayerView(namespace: namespace, floating: false, appScheme: scheme)
                }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else if #available(iOS 26.0, *) {
            content
                .tabViewBottomAccessory { MiniPlayerView(namespace: namespace, floating: false, appScheme: scheme) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content.overlay(alignment: .bottom) {
                if player.current != nil {
                    MiniPlayerView(namespace: namespace, floating: true)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 55)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        #endif
    }
}

/// Keeps scrollable content clear of the floating mini player on iOS 18.
private struct MiniPlayerInset: ViewModifier {
    @Environment(PlayerManager.self) private var player

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: player.current != nil ? 66 : 0)
            }
        }
    }
}

struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        ZStack {
            if let toast = toasts.toast {
                VStack(spacing: 12) {
                    Image(systemName: toast.systemImage)
                        .font(.system(size: 44, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                    Text(toast.message)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 22)
                .padding(.vertical, 22)
                .frame(minWidth: 160, maxWidth: 240)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .allowsHitTesting(false)
    }
}
