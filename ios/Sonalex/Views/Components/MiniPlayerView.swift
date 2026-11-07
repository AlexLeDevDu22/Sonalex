import SwiftUI

struct MiniPlayerView: View {
    let namespace: Namespace.ID
    /// true on iOS 18 (we draw our own floating bar), false inside the iOS 26 tab accessory.
    let floating: Bool
    /// The app's appearance, read outside the bar: iOS 26's glass otherwise flips the text
    /// between black and white depending on what scrolls underneath.
    var appScheme: ColorScheme? = nil

    @Environment(PlayerManager.self) private var player
    @Environment(\.colorScheme) private var localScheme

    var body: some View {
        let track = player.current
        HStack(spacing: 12) {
            ArtworkView(item: track, points: 44, cornerRadius: floating ? 7 : 20, circle: !floating)
                .overlay {
                    // Mix: the old cover slides out to the left while the new one is heard coming in.
                    if let outgoing = player.mixOutgoing, let p = player.mixProgress {
                        ArtworkView(item: outgoing, points: 44, cornerRadius: floating ? 7 : 20, circle: !floating)
                            .offset(x: -14 * p)
                            .scaleEffect(1 - 0.3 * p)
                            .opacity(1 - p)
                            .animation(.linear(duration: 0.15), value: p)
                    }
                }
                .frame(width: floating ? 44 : 32, height: floating ? 44 : 32)
                .overlay {
                    if player.isBuffering && track != nil {
                        ProgressView().tint(.white).controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: floating ? 7 : 20))
                    }
                }
                .matchedTransitionSource(id: "nowPlayingArtwork", in: namespace)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(track?.title ?? "Aucune lecture en cours")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if ConnectManager.shared.isRemote {
                    RemotePlaybackBadge()
                } else if let artist = track?.artistLine, !artist.isEmpty {
                    Text(artist)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .disabled(track == nil)

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 19))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .disabled(track == nil)
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .foregroundStyle(.primary)
        .padding(.leading, floating ? 8 : 10)
        .padding(.trailing, floating ? 10 : 8)
        .frame(height: floating ? 60 : nil)
        .background {
            if floating {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard track != nil else { return }
            player.showNowPlaying = true
        }
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { v in
                guard track != nil else { return }
                if v.translation.height < -30 { player.showNowPlaying = true }
                else if v.translation.width < -60 { player.next() }
                else if v.translation.width > 60 { player.previous() }
            }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: player.current?.id)
        .environment(\.colorScheme, appScheme ?? localScheme)
    }
}

/// Shows the playlist picker from whichever screen is on top: the app's root, or the Now Playing
/// screen when it's open (a sheet asked from under a full-screen cover only appeared once it closed).
private struct AddToPlaylistPresenter: ViewModifier {
    let inNowPlaying: Bool
    @Environment(AppRouter.self) private var router
    @Environment(PlayerManager.self) private var player

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { player.showNowPlaying == inNowPlaying ? router.addToPlaylist : nil },
            set: { router.addToPlaylist = $0 })) { item in
            AddToPlaylistSheet(item: item).appEnvironment()
        }
        .sheet(item: Binding(
            get: { player.showNowPlaying == inNowPlaying ? router.credits : nil },
            set: { router.credits = $0 })) { item in
            CreditsSheet(track: item).appEnvironment()
        }
        // Unstable network and songs not on the device: play only the downloaded ones, or try all?
        .alert("Connexion instable", isPresented: Binding(
            get: { player.showNowPlaying == inNowPlaying && player.offlineChoice != nil },
            set: { if !$0 { player.offlineChoice = nil } }), presenting: player.offlineChoice) { choice in
            Button("Sons téléchargés (\(choice.localCount))") { player.resolveOfflineChoice(localOnly: true) }
            Button("Tout essayer") { player.resolveOfflineChoice(localOnly: false) }
            Button("Annuler", role: .cancel) { player.offlineChoice = nil }
        } message: { _ in
            Text("Le réseau répond mal. Lire seulement les sons sur cet appareil, ou essayer de tout charger ?")
        }
    }
}

extension View {
    func addToPlaylistPresenter(inNowPlaying: Bool) -> some View {
        modifier(AddToPlaylistPresenter(inNowPlaying: inNowPlaying))
    }
}

/// Sheet listing playlists to add a song / album / playlist to.
struct AddToPlaylistSheet: View {
    let item: Item

    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Item] = []
    @State private var loading = true
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
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
                    Button { add(to: pl) } label: {
                        HStack(spacing: 14) {
                            ArtworkView(item: pl, points: 56, cornerRadius: 6).frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pl.title).foregroundStyle(.primary)
                                if let n = pl.childCount {
                                    Text(Format.songCount(n)).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Ajouter à une playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
            .alert("Nouvelle playlist", isPresented: $showNew) {
                TextField("Titre", text: $newName)
                Button("Annuler", role: .cancel) { newName = "" }
                Button("Créer") { create() }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            playlists = (try? await JellyfinClient.shared.items(["IncludeItemTypes": "Playlist", "SortBy": "SortName"],
                                                                 cacheable: false)) ?? []
            loading = false
        }
    }

    private func add(to playlist: Item) {
        if let key = item.externalKey {
            saveOnline(key, into: playlist)
            return
        }
        Task {
            do {
                let ids = try await JellyfinClient.shared.tracks(for: item).map(\.id)
                try await JellyfinClient.shared.addToPlaylist(playlist.id, ids: ids)
                ToastCenter.shared.show("Ajouté à « \(playlist.title) »", systemImage: "text.badge.checkmark")
                dismiss()
            } catch {
                ToastCenter.shared.error(error)
            }
        }
    }

    /// Online song: downloaded into the library and added to the playlist (takes a few seconds).
    private func saveOnline(_ key: String, into playlist: Item) {
        ToastCenter.shared.show("Ajout à « \(playlist.title) »…", systemImage: "arrow.down.circle")
        dismiss()
        Task {
            do {
                let saved = try await SonalexAPI.shared.save(key, favorite: false, playlistId: playlist.id)
                PlayerManager.shared.replaceTrack(key: key, with: saved)
                ToastCenter.shared.show("Ajouté à « \(playlist.title) »", systemImage: "text.badge.checkmark")
            } catch {
                ToastCenter.shared.error(error)
            }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        Task {
            do {
                if let key = item.externalKey {
                    // New playlist, then the online song is downloaded straight into it.
                    guard let id = try await JellyfinClient.shared.createPlaylist(name: name, ids: []) else { return }
                    saveOnline(key, into: Item(id: id, name: name, type: ItemKind.playlist))
                    return
                }
                let ids = try await JellyfinClient.shared.tracks(for: item).map(\.id)
                try await JellyfinClient.shared.createPlaylist(name: name, ids: ids)
                ToastCenter.shared.show("Playlist créée", systemImage: "music.note.list")
                dismiss()
            } catch {
                ToastCenter.shared.error(error)
            }
        }
    }
}
