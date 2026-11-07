import SwiftUI
import UserNotifications

@main
struct SonalexApp: App {
    @State private var session = SessionStore.shared
    @State private var player = PlayerManager.shared
    @State private var router = AppRouter.shared
    @State private var favorites = FavoritesStore.shared
    @State private var toasts = ToastCenter.shared
    @State private var ambilight = AmbilightClient.shared

    init() {
        // Artwork is cached on disk across launches.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 1 << 30)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(player)
                .environment(router)
                .environment(favorites)
                .environment(toasts)
                .environment(ambilight)
                .tint(.appAccent)
        }
        .commands { PlaybackCommands() }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let s = session.session {
                #if targetEnvironment(macCatalyst)
                MacRootView().id(s.userId + s.server)
                #else
                MainTabView().id(s.userId + s.server)
                #endif
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.session == nil)
        .task(id: session.session?.userId) {
            guard session.session != nil else { return }
            Connectivity.shared.start()
            UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
            SocialReporter.shared.start()
            await ServerFeatures.shared.refresh()
            // Songs on this device: offline playlists follow their changes, automatic downloads.
            await OfflineStore.shared.syncPlaylists()
            await OfflineStore.shared.autoSync()
        }
        .onChange(of: scenePhase) { _, phase in
            // Back to the app: anyone asking to join meanwhile?
            if phase == .active, session.session != nil { Task { await Community.shared.refreshRequests() } }
        }
        .onOpenURL { NowPlayingExport.handle($0) }
    }
}
