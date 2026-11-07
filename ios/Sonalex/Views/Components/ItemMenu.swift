import SwiftUI

/// Context-menu content shared by every song / album / playlist / artist in the app.
struct ItemMenu: View {
    let item: Item
    var playlist: PlaylistContext? = nil
    var onRemoved: (() -> Void)? = nil

    @Environment(PlayerManager.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(FavoritesStore.self) private var favorites

    var body: some View {
        let api = JellyfinClient.shared
        let toast = ToastCenter.shared

        if !item.isSong {
            Section {
                Button { withTracks { player.play($0, source: item.title, sourceId: item.playbackSourceId) } } label: {
                    Label("Lire", systemImage: "play.fill")
                }
                Button { withTracks { player.play($0, shuffle: true, source: item.title, sourceId: item.playbackSourceId) } } label: {
                    Label("Lecture aléatoire", systemImage: "shuffle")
                }
            }
        }

        Section {
            Button {
                withTracks { player.playNext($0); toast.show("Lu ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
            } label: { Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button {
                withTracks { player.addToQueue($0); toast.show("Ajouté à la file", systemImage: "text.line.last.and.arrowtriangle.forward") }
            } label: { Label("Lire en dernier", systemImage: "text.line.last.and.arrowtriangle.forward") }
        }

        Section {
            if !item.isArtist {
                Button { router.addToPlaylist = item } label: {
                    Label("Ajouter à une playlist…", systemImage: "text.badge.plus")
                }
            }
            if !item.isExternal, item.isSong || item.isAlbum || item.isPlaylist {
                let store = OfflineStore.shared
                let here = item.isPlaylist ? store.isOffline(playlist: item) : (item.isSong && store.isDownloaded(item))
                Button {
                    if item.isPlaylist {
                        store.setOffline(playlist: item, !here)
                    } else if here {
                        store.remove([item])
                    } else {
                        withTracks { store.download($0) }
                    }
                } label: {
                    Label(here ? "Retirer de cet appareil" : "Télécharger sur cet appareil",
                          systemImage: here ? "minus.circle" : "arrow.down.circle")
                }
                if item.isAlbum {
                    Button { withTracks { store.remove($0) } } label: {
                        Label("Retirer l’album de cet appareil", systemImage: "minus.circle")
                    }
                }
            }
            if !item.isPlaylist {
                let fav = favorites.isFavorite(item)
                Button { favorites.toggle(item) } label: {
                    Label(fav ? "Retirer des favoris" : "Ajouter aux favoris", systemImage: fav ? "star.slash" : "star")
                }
            }
            if item.isSong || item.isArtist || item.isAlbum {
                Button {
                    Task {
                        do {
                            if item.isSong, ServerFeatures.shared.online {
                                // Endless station: this song, then recommendations that keep coming.
                                let next = try await SonalexAPI.shared.radio(seed: item, recent: ListeningHistory.shared.recent(150), limit: 25)
                                player.play([item] + next, shuffle: false, source: "Station \(item.title)", autoplay: true)
                                return
                            }
                            let mix = try await (item.isArtist ? MixStore.shared.tracks(for: MixStore.station(item.id)) : api.instantMix(item.id))
                            player.play(mix, shuffle: false, source: "Station \(item.title)",
                                        sourceId: item.isArtist ? "station:\(item.id)" : nil)
                        } catch { toast.error(error) }
                    }
                } label: { Label("Créer une station", systemImage: "dot.radiowaves.left.and.right") }
            }
        }

        Section {
            if item.isSong, let route = item.albumRoute {
                Button {
                    NavDiagnostics.log("tap.menuAlbum", ["item": item.title])
                    router.open(route)
                } label: { Label("Aller à l’album", systemImage: "square.stack") }
            }
            let artists = item.isSong ? (item.artistItems ?? []) : (item.albumArtists ?? [])
            if artists.count > 1 {
                Menu {
                    ForEach(artists, id: \.id) { a in
                        Button(a.name ?? "") {
                            NavDiagnostics.log("tap.menuArtist", ["artist": a.name ?? ""])
                            router.open(Item.artistRoute(a))
                        }
                    }
                } label: { Label("Aller à l’artiste", systemImage: "music.microphone") }
            } else if item.isSong || item.isAlbum, let artist = (item.isSong ? item.firstArtist : item.firstAlbumArtist) {
                Button {
                    NavDiagnostics.log("tap.menuArtist", ["artist": artist.name ?? ""])
                    router.open(Item.artistRoute(artist))
                } label: {
                    Label("Aller à l’artiste", systemImage: "music.microphone")
                }
            }
            if item.isSong, ServerFeatures.shared.online {
                Button { router.credits = item } label: { Label("Crédits", systemImage: "person.2") }
            }
        }

        if let playlist {
            Section {
                Button(role: .destructive) {
                    Task {
                        do {
                            try await api.removeFromPlaylist(playlist.playlistId, entryIds: [playlist.entryId])
                            onRemoved?()
                            toast.show("Retiré de la playlist", systemImage: "minus.circle")
                        } catch { toast.error(error) }
                    }
                } label: { Label("Retirer de la playlist", systemImage: "minus.circle") }
            }
        }
    }

    private func withTracks(_ body: @escaping ([Item]) -> Void) {
        if item.isSong { body([item]); return }
        Task {
            do {
                let tracks = try await JellyfinClient.shared.tracks(for: item)
                body(tracks)
            } catch {
                ToastCenter.shared.error(error)
            }
        }
    }
}
