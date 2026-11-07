import SwiftUI

/// "Crédits": who performs, produced, wrote, mixed… a song (from Genius, through the Pi).
struct CreditsSheet: View {
    let track: Item

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var credits: SongCredits?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ArtworkView(item: track, points: 64, cornerRadius: 6)
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.headline).lineLimit(2)
                            Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            if let line = [credits?.album, credits?.releaseDate].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                                Text(line).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                if let credits {
                    ForEach(credits.sections, id: \.role) { section in
                        Section(section.role) {
                            ForEach(section.people, id: \.name) { person in
                                PersonRow(person: person)
                            }
                        }
                    }
                    if let url = credits.url.flatMap(URL.init(string:)) {
                        Section {
                            Button { openURL(url) } label: {
                                Label("Voir sur Genius", systemImage: "arrow.up.right.square")
                            }
                        } footer: {
                            Text("Crédits fournis par Genius.")
                        }
                    }
                }
            }
            .overlay {
                if credits == nil && !failed {
                    ProgressView()
                } else if failed || credits?.found == false || credits?.sections.isEmpty == true {
                    ContentUnavailableView("Pas de crédits", systemImage: "person.2.slash",
                                           description: Text(failed ? "Le serveur ne répond pas pour le moment."
                                                                    : "Aucun crédit trouvé pour ce morceau."))
                }
            }
            .navigationTitle("Crédits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            let artist = track.firstArtist?.name ?? track.artistLine
            do {
                credits = try await SonalexAPI.shared.credits(title: track.title, artist: artist)
            } catch {
                failed = true
            }
        }
    }
}

private struct PersonRow: View {
    let person: SongCredits.Person

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let s = person.image, !s.isEmpty, let url = URL(string: s) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { placeholder }
                } else {
                    placeholder
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            Text(person.name)
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color(.secondarySystemFill))
            Text(String(person.name.prefix(1)).uppercased())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
