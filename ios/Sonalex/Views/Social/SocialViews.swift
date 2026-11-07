import Charts
import SwiftUI

// MARK: - Small pieces

/// A user's initial on their color (always the same color for the same name).
struct Avatar: View {
    let name: String
    var size: CGFloat = 44

    static let palette: [Color] = [Color(red: 0.49, green: 0.36, blue: 1), Color(red: 1, green: 0.36, blue: 0.62),
                                   Color(red: 0.24, green: 0.81, blue: 0.56), Color(red: 1, green: 0.71, blue: 0.28),
                                   Color(red: 0.3, green: 0.76, blue: 1), Color(red: 0.69, green: 0.47, blue: 1),
                                   Color(red: 1, green: 0.48, blue: 0.35), Color(red: 0.36, green: 0.88, blue: 0.82)]

    var color: Color { Self.palette[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.palette.count] }

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom), in: Circle())
            .accessibilityHidden(true)
    }
}

private func minutesText(_ m: Int) -> String {
    m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
}

/// "Martin likes it too · in Léa's library": under the title in Now Playing.
struct SharedWithLabel: View {
    let track: Item?
    @State private var sharers: [TrackSharer] = []

    var body: some View {
        Group {
            if !sharers.isEmpty {
                let liked = sharers.filter(\.liked).map(\.name)
                let others = sharers.filter { !$0.liked }.map(\.name)
                HStack(spacing: 5) {
                    Image(systemName: liked.isEmpty ? "person.2.fill" : "heart.fill")
                    Text(Self.describe(liked: liked, others: others))
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .transition(.opacity)
            }
        }
        .task(id: track?.id) {
            sharers = []
            guard let track else { return }
            let found = await Community.shared.sharers(of: track)
            withAnimation { sharers = found }
        }
    }

    static func describe(liked: [String], others: [String]) -> String {
        func list(_ names: [String]) -> String {
            names.count <= 2 ? names.joined(separator: " & ") : "\(names[0]), \(names[1]) & \(names.count - 2) more"
        }
        if !liked.isEmpty && !others.isEmpty { return "\(list(liked)) \(liked.count == 1 ? "likes" : "like") it · \(list(others)) \(others.count == 1 ? "has" : "have") it" }
        if !liked.isEmpty { return "\(list(liked)) \(liked.count == 1 ? "likes" : "like") it too" }
        return "Also in \(list(others))’s library"
    }
}

/// A song of a friend (with its artwork); playing it plays the viewer's own copy when they have one.
private struct SocialSongRow: View {
    let song: SocialSong
    var detail: String? = nil
    @Environment(PlayerManager.self) private var player

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ArtworkView(url: song.artworkURL, cornerRadius: 6)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title ?? "").font(.body).lineLimit(1)
                    Text(song.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let detail {
                    Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if song.yourItemId != nil {
                    Image(systemName: "play.circle.fill").foregroundStyle(Color.appAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(song.yourItemId == nil)
    }

    private func play() {
        guard let id = song.yourItemId else { return }
        Task {
            if let item = try? await JellyfinClient.shared.item(id) { player.play([item], autoplay: true) }
        }
    }
}

// MARK: - Friends

/// Everyone on the server: who's listening right now, their song of the moment, their week.
struct FriendsView: View {
    @State private var community = Community.shared
    @State private var loaded = false

    var body: some View {
        List {
            if community.isAdmin, !community.requests.isEmpty {
                Section {
                    NavigationLink { AccessRequestsView() } label: {
                        Label("\(community.requests.count) waiting to join", systemImage: "person.badge.clock")
                            .foregroundStyle(Color.appAccent)
                    }
                }
            }
            Section {
                ForEach(community.users) { user in
                    NavigationLink(value: Route.friend(id: user.id, name: user.name)) {
                        FriendRow(user: user)
                    }
                }
            } footer: {
                if loaded && community.users.count <= 1 {
                    Text("Nobody else on this server yet. Friends join from the app: “Create an Account”.")
                }
            }
        }
        .navigationTitle("Friends")
        .overlay { if !loaded { ProgressView() } }
        .refreshable { await community.refreshUsers() }
        .task {
            await community.refreshUsers()
            await community.refreshRequests()
            loaded = true
        }
    }
}

private struct FriendRow: View {
    let user: SocialUser

    var body: some View {
        HStack(spacing: 14) {
            Avatar(name: user.name)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user.isMe == true ? "\(user.name) (you)" : user.name).font(.headline)
                    if user.admin == true { Image(systemName: "crown.fill").font(.caption).foregroundStyle(.orange) }
                }
                if let now = user.nowPlaying {
                    Label("\(now.title ?? "") — \(now.artist ?? "")", systemImage: "waveform")
                        .font(.subheadline)
                        .foregroundStyle(Color.appAccent)
                        .lineLimit(1)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else if let moment = user.moment {
                    Label("\(moment.title ?? "") — \(moment.artist ?? "")", systemImage: "flame.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text("\(minutesText(user.weekMinutes ?? 0)) this week")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Avatars of the friends, on Home (with who's listening right now).
struct FriendsShelf: View {
    @State private var community = Community.shared

    var body: some View {
        Group {
            if ServerFeatures.shared.accounts, !community.friends.isEmpty {
                Shelf("Friends", destination: .friends) {
                    ForEach(community.friends) { user in
                        NavigationLink(value: Route.friend(id: user.id, name: user.name)) {
                            VStack(spacing: 6) {
                                Avatar(name: user.name, size: 72)
                                    .overlay(alignment: .bottomTrailing) {
                                        if user.nowPlaying != nil {
                                            Image(systemName: "waveform")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                                .padding(5)
                                                .background(Color.appAccent, in: Circle())
                                        }
                                    }
                                Text(user.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(user.nowPlaying?.title ?? user.moment?.title ?? " ")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 92)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await community.refreshUsers() }
    }
}

// MARK: - Profile

struct FriendProfileView: View {
    let userId: String
    let name: String

    @State private var profile: UserProfile?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let profile {
                content(profile)
            } else if let error {
                ContentUnavailableView("Profile Unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                                       description: Text(error))
                    .padding(.top, 60)
            } else {
                ProgressView().padding(.top, 120)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { profile = try await Community.shared.profile(userId) } catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func content(_ p: UserProfile) -> some View {
        let s = p.stats
        VStack(alignment: .leading, spacing: 26) {
            VStack(spacing: 10) {
                Avatar(name: p.name, size: 96)
                    .shadow(color: Avatar(name: p.name).color.opacity(0.4), radius: 18, y: 8)
                Text(p.name).font(.title.bold())
                HStack(spacing: 8) {
                    if let provider = p.provider, provider != "none" {
                        Label(provider.capitalized, systemImage: "music.note.list")
                    }
                    if let joined = p.joinedAt {
                        Text("Since \(Date(timeIntervalSince1970: joined).formatted(.dateTime.month(.wide).year()))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            if let now = p.nowPlaying {
                card(title: "Listening Now", systemImage: "waveform", tint: .appAccent) { SocialSongRow(song: now) }
            }
            if let moment = p.moment {
                card(title: "Song of the Moment", systemImage: "flame.fill", tint: .orange) { SocialSongRow(song: moment) }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                tile(minutesText(s.periodMinutes), "listened in \(s.periodDays) days", "headphones")
                tile("\(s.periodPlays)", "songs played", "play.circle")
                tile("\(p.library)", "songs in the library", "music.note.house")
                tile("\(p.favorites)", "favorites", "star.fill")
            }

            if s.byDay.contains(where: { $0 > 0 }) {
                card(title: "Last Two Weeks", systemImage: "chart.bar.fill", tint: .appAccent) {
                    Chart(Array(s.byDay.enumerated()), id: \.offset) { i, minutes in
                        BarMark(x: .value("Day", i), y: .value("Minutes", minutes))
                            .foregroundStyle(Color.appAccent.gradient)
                            .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks(values: [0, 7, 13]) { value in
                            AxisValueLabel {
                                if let i = value.as(Int.self) { Text(Self.dayLabel(13 - i)) }
                            }
                        }
                    }
                    .frame(height: 150)
                }
                card(title: "When \(p.name) Listens", systemImage: "clock.fill", tint: .appAccent) {
                    Chart(Array(s.byHour.enumerated()), id: \.offset) { hour, minutes in
                        BarMark(x: .value("Hour", hour), y: .value("Minutes", minutes))
                            .foregroundStyle(Color.appAccent.gradient)
                            .cornerRadius(2)
                    }
                    .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
                    .frame(height: 110)
                }
            }

            if !s.topSongs.isEmpty {
                card(title: "Top Songs", systemImage: "music.note", tint: .appAccent) {
                    ForEach(Array(s.topSongs.prefix(8).enumerated()), id: \.offset) { i, song in
                        SocialSongRow(song: song, detail: song.plays.map { "\($0)×" })
                        if i < min(s.topSongs.count, 8) - 1 { Divider() }
                    }
                }
            }
            if !s.topArtists.isEmpty {
                card(title: "Top Artists", systemImage: "music.microphone", tint: .appAccent) {
                    ForEach(Array(s.topArtists.enumerated()), id: \.offset) { i, artist in
                        HStack {
                            Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                            Text(artist.name).lineLimit(1)
                            Spacer()
                            Text("\(artist.plays)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !s.recent.isEmpty {
                card(title: "Lately", systemImage: "clock.arrow.circlepath", tint: .appAccent) {
                    ForEach(Array(s.recent.prefix(8).enumerated()), id: \.offset) { _, song in
                        SocialSongRow(song: song, detail: song.at.map { Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)) })
                    }
                }
            }
            Text("\(minutesText(s.minutes)) listened on Sonalex, \(s.plays) songs.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private static func dayLabel(_ daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func tile(_ value: String, _ label: String, _ systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(Color.appAccent)
            Text(value).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func card<C: View>(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Access requests (server's owner)

struct AccessRequestsView: View {
    @State private var community = Community.shared
    @State private var working: String?

    var body: some View {
        List {
            if community.requests.isEmpty {
                ContentUnavailableView("No Requests", systemImage: "person.badge.clock",
                                       description: Text("When friends create an account from the app, they show up here (and you get a notification)."))
            }
            ForEach(community.requests) { request in
                HStack(spacing: 14) {
                    Avatar(name: request.name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.name).font(.headline)
                        Text([request.provider == "none" ? "No music service" : request.provider.capitalized,
                              request.deezer?.name, Date(timeIntervalSince1970: request.createdAt).formatted(.relative(presentation: .named))]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if working == request.id {
                        ProgressView()
                    } else {
                        Button { decide(request, accept: false) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        Button { decide(request, accept: true) } label: { Image(systemName: "checkmark") }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Access Requests")
        .refreshable { await community.refreshRequests() }
        .task { await community.refreshRequests() }
    }

    private func decide(_ request: AccessRequest, accept: Bool) {
        working = request.id
        Task {
            defer { working = nil }
            do {
                if accept { try await community.approve(request) } else { try await community.deny(request) }
            } catch {
                ToastCenter.shared.error(error)
            }
        }
    }
}

// MARK: - Music service

/// Connect Spotify (sign in) or a public Deezer profile: their songs come into the library.
struct MusicServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var community = Community.shared
    @State private var deezer = ""
    @State private var working = false
    @State private var visible = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Connected", value: connectedText)
                } footer: {
                    Text("Your liked songs and playlists come into your library on this server, every night (and now, after connecting). Songs a friend already has are shared, not downloaded again.")
                }
                Section("Spotify") {
                    Button {
                        run { let name = try await SpotifyConnect.shared.connect(); ToastCenter.shared.show("Connected to \(name)", systemImage: "checkmark") }
                    } label: {
                        Label(community.me?.spotifyConnected == true ? "Reconnect Spotify" : "Connect Spotify", systemImage: "link")
                    }
                }
                Section {
                    TextField("Deezer profile link", text: $deezer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use This Profile") {
                        run {
                            _ = try await SonalexAPI.shared.send("/api/me/deezer", method: "PUT", body: ["profile": deezer], timeout: 30)
                            ToastCenter.shared.show("Deezer profile connected", systemImage: "checkmark")
                        }
                    }
                    .disabled(deezer.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Deezer")
                } footer: {
                    Text("Your profile must be public (Deezer → Settings → Privacy). Deezer is read only: what you change here doesn't go back to Deezer.")
                }
                if let provider = community.me?.provider, provider != "none" {
                    Section {
                        Button("Sync Now") {
                            run {
                                _ = try await SonalexAPI.shared.send("/api/me/sync", method: "POST")
                                ToastCenter.shared.show("Sync started", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                }
                Section {
                    Toggle("Show Me to Friends", isOn: $visible)
                        .onChange(of: visible) { _, value in Task { await community.setVisible(value) } }
                } footer: {
                    Text("Friends on this server see your profile, what you listen to and your favorites.")
                }
            }
            .disabled(working)
            .navigationTitle("Music Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                await community.refreshMe()
                visible = community.me?.visible ?? true
            }
        }
    }

    private var connectedText: String {
        switch community.me?.provider {
        case "spotify": community.me?.spotifyConnected == true ? "Spotify" : "Spotify (sign in needed)"
        case "deezer": "Deezer" + (community.me?.deezerName.map { " · \($0)" } ?? "")
        default: "Nothing"
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do {
                try await action()
                await community.refreshMe()
            } catch {
                ToastCenter.shared.error(error)
            }
        }
    }
}
