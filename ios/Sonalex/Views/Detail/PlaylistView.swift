import SwiftUI

struct PlaylistView: View {
    let playlist: Item

    @Environment(PlayerManager.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [Item] = []
    @State private var loading = true
    @State private var showTitle = false
    @State private var confirmDelete = false
    @State private var addingSongs = false

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

            Button { addingSongs = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 48, height: 48)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text("Add Songs").foregroundStyle(Color.appAccent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))

            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40).listRowSeparator(.hidden)
            } else if tracks.isEmpty {
                Text("This playlist is empty.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .listRowSeparator(.hidden)
            }

            ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                TrackRow(track: track,
                         playlist: track.playlistItemId.map { PlaylistContext(playlistId: playlist.id, entryId: $0) },
                         onRemoved: { Task { await load() } }) {
                    player.play(tracks, startAt: i, source: playlist.title, sourceId: playlist.playbackSourceId)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
            }

            if !tracks.isEmpty {
                Text("\(Format.songCount(tracks.count)), \(Format.totalDuration(tracks.reduce(0) { $0 + $1.duration }))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))
            }
        }
        .listStyle(.plain)
        .navigationTitle(showTitle ? playlist.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top > 360
        } action: { _, past in
            withAnimation(.easeInOut(duration: 0.2)) { showTitle = past }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Keep the whole playlist on this device (follows its changes).
                let offline = OfflineStore.shared.isOffline(playlist: playlist)
                Button { OfflineStore.shared.setOffline(playlist: playlist, !offline) } label: {
                    Image(systemName: offline ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .help(offline ? "Remove from This Device" : "Download to This Device")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { addingSongs = true } label: { Label("Add Songs", systemImage: "plus") }
                    ItemMenu(item: playlist)
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .sheet(isPresented: $addingSongs) {
            AddSongsSheet(playlist: playlist, alreadyIn: Set(tracks.map(\.id))) { Task { await load() } }
                .appEnvironment()
        }
        .confirmationDialog("Delete “\(playlist.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                Task {
                    do {
                        try await JellyfinClient.shared.deleteItem(playlist.id)
                        dismiss()
                    } catch { ToastCenter.shared.error(error) }
                }
            }
        }
        .libraryTask { await load() }
    }

    private var header: some View {
        DetailHeader {
            ArtworkView(item: playlist, points: 270, cornerRadius: 10)
        } info: {
            Text(playlist.title)
                .font(.title2.bold())
            Text("Playlist")
                .font(.title3)
                .foregroundStyle(.secondary)
            PlayShuffleButtons(onPlay: { player.play(tracks, shuffle: false, source: playlist.title, sourceId: playlist.playbackSourceId) },
                               onShuffle: { player.play(tracks, shuffle: true, source: playlist.title, sourceId: playlist.playbackSourceId) },
                               ready: !tracks.isEmpty)
                .padding(.top, 16)
                .disabled(!loading && tracks.isEmpty)
        }
    }

    private func load() async {
        if let t = try? await JellyfinClient.shared.playlistTracks(playlist.id) {
            withAnimation { tracks = t }
        }
        loading = false
    }
}
