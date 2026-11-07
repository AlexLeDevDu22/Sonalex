import SwiftUI

/// Pick library songs to add to a playlist: search, select as many as you like, add them all.
/// Songs already in the playlist show as selected and can't be toggled.
struct AddSongsSheet: View {
    let playlist: Item
    let alreadyIn: Set<String>
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var songs: [Item] = []
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var loading = true
    @State private var saving = false

    private var shown: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return songs }
        return songs.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artistLine.localizedCaseInsensitiveContains(q)
                || ($0.album ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { song in
                    row(song)
                }
            }
            .listStyle(.plain)
            .overlay {
                if loading {
                    ProgressView()
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search your songs")
            .navigationTitle("Add to “\(playlist.title)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        add()
                    } label: {
                        if saving { ProgressView() } else {
                            Text(selected.isEmpty ? "Add" : "Add (\(selected.count))").bold()
                        }
                    }
                    .disabled(selected.isEmpty || saving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    Text("\(Format.songCount(selected.count)) selected")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selected.isEmpty)
        }
        .task {
            songs = (try? await JellyfinClient.shared.items(
                ["IncludeItemTypes": "Audio", "SortBy": "DateCreated,SortName", "SortOrder": "Descending"])) ?? []
            loading = false
        }
    }

    private func row(_ song: Item) -> some View {
        let inPlaylist = alreadyIn.contains(song.id)
        let isSelected = inPlaylist || selected.contains(song.id)
        return Button {
            guard !inPlaylist else { return }
            if selected.contains(song.id) { selected.remove(song.id) } else { selected.insert(song.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(inPlaylist ? Color.secondary : (isSelected ? Color.appAccent : Color.secondary))
                    .contentTransition(.symbolEffect(.replace))
                ArtworkView(item: song, points: 44, cornerRadius: 5)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).lineLimit(1)
                    Text(inPlaylist ? "Already in the playlist" : song.artistLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .opacity(inPlaylist ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inPlaylist)
        .sensoryFeedback(.selection, trigger: selected.contains(song.id))
    }

    private func add() {
        saving = true
        // Keep the order of the list (newest first).
        let ids = songs.map(\.id).filter { selected.contains($0) }
        Task {
            do {
                try await JellyfinClient.shared.addToPlaylist(playlist.id, ids: ids)
                ToastCenter.shared.show("\(Format.songCount(ids.count)) added",
                                        systemImage: "text.badge.checkmark")
                onAdded()
                dismiss()
            } catch {
                ToastCenter.shared.error(error)
            }
            saving = false
        }
    }
}
