import SwiftUI

struct PlaylistContext: Hashable {
    let playlistId: String
    let entryId: String
}

/// A song row. Album pages show the track number, other lists show the artwork.
struct TrackRow: View {
    enum Leading { case number, artwork, none }

    let track: Item
    var leading: Leading = .artwork
    var showArtist = true
    var playlist: PlaylistContext? = nil
    var onRemoved: (() -> Void)? = nil
    /// In online lists: mark songs already downloaded in the library.
    var showDownloaded = false
    /// Position shown in the number column (album pages), whatever the file's tags say.
    var number: Int? = nil
    let action: () -> Void

    @Environment(PlayerManager.self) private var player
    @Environment(FavoritesStore.self) private var favorites

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 4) {
            Button { MomentFavorite.shared.picked(track); action() } label: {
                HStack(spacing: 12) {
                    leadingView
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(track.title)
                                .font(.body)
                                .foregroundStyle(isCurrent ? Color.appAccent : .primary)
                                .lineLimit(1)
                            if MomentFavorite.shared.isMoment(track) { MomentBadge() }
                        }
                        if showArtist, !track.artistLine.isEmpty {
                            Text(track.artistLine)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if OfflineStore.shared.isDownloaded(track) {
                        // On this iPhone / Mac: plays instantly, even offline.
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appAccent)
                            .accessibilityLabel("On This Device")
                    } else if OfflineStore.shared.downloading.contains(track.id) {
                        ProgressView().controlSize(.mini)
                    } else if showDownloaded && !track.isExternal {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("In Library")
                    }
                    if favorites.isFavorite(track) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                ItemMenu(item: track, playlist: playlist, onRemoved: onRemoved)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            ItemMenu(item: track, playlist: playlist, onRemoved: onRemoved)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                player.playNext([track])
                ToastCenter.shared.show("Playing Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                player.addToQueue([track])
                ToastCenter.shared.show("Added to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
                .tint(.orange)
        }
    }

    @ViewBuilder private var leadingView: some View {
        switch leading {
        case .number:
            ZStack {
                if isCurrent && player.isBuffering {
                    ProgressView().controlSize(.small)
                } else if isCurrent {
                    EqualizerBars(animating: player.isPlaying)
                } else {
                    Text((number ?? track.indexNumber).map(String.init) ?? "")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26)
        case .artwork:
            ZStack {
                ArtworkView(item: track, points: 48, cornerRadius: 5)
                if isCurrent { PlayingOverlay() }
            }
            .frame(width: 48, height: 48)
        case .none:
            EmptyView()
        }
    }
}

/// Compact row used inside the horizontal "song grids" (Top titres, Les plus écoutés…).
struct SongCell: View {
    let track: Item
    let action: () -> Void
    @Environment(PlayerManager.self) private var player

    var body: some View {
        HStack(spacing: 4) {
            Button { MomentFavorite.shared.picked(track); action() } label: {
                HStack(spacing: 12) {
                    ZStack {
                        ArtworkView(item: track, points: 50, cornerRadius: 5)
                        if player.current?.id == track.id { PlayingOverlay() }
                    }
                    .frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(track.title)
                                .font(.body)
                                .foregroundStyle(player.current?.id == track.id ? Color.appAccent : .primary)
                                .lineLimit(1)
                            if MomentFavorite.shared.isMoment(track) { MomentBadge() }
                        }
                        Text([track.artistLine, track.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                ItemMenu(item: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu { ItemMenu(item: track) }
    }
}

/// Library-style row for albums / playlists / artists in vertical lists.
struct CollectionRow: View {
    let item: Item
    var subtitle: String?

    @Environment(PlayerManager.self) private var player

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(item: item, points: 56, cornerRadius: 6, circle: item.isArtist)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if player.isQueueSource(item) {
                        EqualizerBars(animating: player.isPlaying).scaleEffect(0.75).frame(width: 14, height: 11)
                    }
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(player.isQueueSource(item) ? Color.appAccent : .primary)
                        .lineLimit(1)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

extension Item {
    /// Matches `PlayerManager.sourceId` when this album / playlist / artist / genre is what's playing.
    var playbackSourceId: String? {
        switch type {
        case ItemKind.album: "album:\(id)"
        case ItemKind.playlist: "playlist:\(id)"
        case ItemKind.artist: "artist:\(id)"
        case ItemKind.genre: "genre:\(id)"
        default: nil
        }
    }

    var route: Route? {
        switch type {
        case ItemKind.album: .album(self)
        case ItemKind.artist: .artist(self)
        case ItemKind.playlist: .playlist(self)
        case ItemKind.genre: .genre(self)
        default: nil
        }
    }

    var collectionSubtitle: String {
        switch type {
        case ItemKind.album: return ["Album", albumArtistLine].filter { !$0.isEmpty }.joined(separator: " · ")
        case ItemKind.playlist: return childCount.map { "Playlist · " + Format.songCount($0) } ?? "Playlist"
        case ItemKind.artist: return "Artist"
        default: return artistLine
        }
    }
}

/// Over the artwork of the song that's playing: equalizer, or a spinner while an online song loads.
struct PlayingOverlay: View {
    var cornerRadius: CGFloat = 5
    @Environment(PlayerManager.self) private var player

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.black.opacity(0.35))
            if player.isBuffering {
                ProgressView().tint(.white).controlSize(.small)
            } else {
                EqualizerBars(animating: player.isPlaying, color: .white)
            }
        }
    }
}

/// Small flame next to the favourite of the moment.
struct MomentBadge: View {
    var body: some View {
        Image(systemName: "flame.fill")
            .font(.caption2)
            .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
            .accessibilityLabel("Song of the Moment")
    }
}
