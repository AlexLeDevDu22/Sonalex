import SwiftUI

// MARK: - Lyrics

struct LyricsView: View {
    let track: Item

    @Environment(PlayerManager.self) private var player
    @State private var lines: [LyricLine]? = nil
    @State private var loading = true
    @State private var lastUserScroll = Date.distantPast

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lines {
                if lines.contains(where: { $0.start != nil }) {
                    synced(lines)
                } else {
                    plain(lines)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 40))
                    Text("Lyrics Unavailable")
                        .font(.title3.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: track.id) {
            loading = true
            lines = try? await JellyfinClient.shared.lyrics(track.id)
            loading = false
        }
    }

    private func activeIndex(_ lines: [LyricLine]) -> Int {
        let ticks = Int64((player.currentTime + 0.25) * 10_000_000)
        var active = -1
        for (i, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= ticks { active = i } else { break }
        }
        return active
    }

    private func synced(_ lines: [LyricLine]) -> some View {
        let active = activeIndex(lines)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let text = (line.text ?? "").trimmingCharacters(in: .whitespaces)
                        let isActive = i == active
                        // The line being sung: full size and bright; the others smaller and dimmed.
                        Text(text.isEmpty ? "♪" : text)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white.opacity(isActive ? 1 : (i < active ? 0.22 : 0.35)))
                            .blur(radius: isActive || abs(i - active) > 6 ? 0 : 0.8)
                            .scaleEffect(isActive ? 1.06 : 0.86, anchor: .leading)
                            .shadow(color: .white.opacity(isActive ? 0.35 : 0), radius: 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let start = line.start { player.seek(to: Double(start) / 10_000_000) }
                            }
                            .id(i)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isActive)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 300)
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                       .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .simultaneousGesture(DragGesture().onChanged { _ in lastUserScroll = Date() })
            .onAppear { proxy.scrollTo(max(active, 0), anchor: UnitPoint(x: 0, y: 0.25)) }
            .onChange(of: active) { _, new in
                guard new >= 0, Date().timeIntervalSince(lastUserScroll) > 3 else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.9)) {
                    proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.25))
                }
            }
        }
    }

    private func plain(_ lines: [LyricLine]) -> some View {
        ScrollView(showsIndicators: false) {
            // No timestamps for this song (LRCLIB only has the text): nothing to follow.
            Label("Lyrics not synced", systemImage: "text.alignleft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 20)
            Text(lines.compactMap(\.text).joined(separator: "\n"))
                .font(.system(size: 22, weight: .semibold))
                .lineSpacing(8)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
        }
    }
}

// MARK: - Queue

struct QueueView: View {
    @Environment(PlayerManager.self) private var player

    var body: some View {
        List {
            Section {
                ForEach(player.upcoming) { entry in
                    QueueRow(track: entry.track)
                        .contentShape(Rectangle())
                        .onTapGesture { player.jump(to: entry.id) }
                        .contextMenu {
                            Button(role: .destructive) { player.removeUpcoming(id: entry.id) } label: {
                                Label("Remove from Queue", systemImage: "minus.circle")
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.15))
                        .listRowInsets(EdgeInsets(top: 6, leading: 28, bottom: 6, trailing: 20))
                }
                .onMove { player.moveUpcoming(from: $0, to: $1) }

                if player.isLoadingRadio {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white).controlSize(.small)
                        Text("Autoplay: finding songs…")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 10, leading: 28, bottom: 10, trailing: 20))
                } else if player.upcoming.isEmpty {
                    Text("Nothing up next")
                        .foregroundStyle(.white.opacity(0.5))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 20))
                }
            } header: {
                header
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .mask(
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Up Next")
                    .font(.headline)
                    .foregroundStyle(.white)
                if let source = player.sourceName {
                    Text("Playing from \(source)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer()
            toggle(systemImage: "shuffle", active: player.shuffle) { player.toggleShuffle() }
            toggle(systemImage: player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                player.cycleRepeat()
            }
            // Autoplay (∞): endless recommendations once the queue runs out.
            if ServerFeatures.shared.online {
                toggle(systemImage: "infinity", active: player.autoplay) { player.toggleAutoplay() }
            }
            // Mix: DJ-style transitions between the songs, made by the Pi.
            if ServerFeatures.shared.companion {
                toggle(systemImage: "wand.and.stars", active: player.mixEnabled) {
                    player.mixEnabled.toggle()
                    ToastCenter.shared.show(player.mixEnabled ? "Mix on: transitions between songs"
                                                              : "Mix off", systemImage: "wand.and.stars")
                }
            }
            Menu {
                Button(role: .destructive) { player.clearUpcoming() } label: {
                    Label("Clear Queue", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 30)
            }
        }
        .textCase(nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets())
    }

    private func toggle(systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.black.opacity(0.8) : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 46, height: 30)
                .background(Capsule().fill(Color.white.opacity(active ? 0.9 : 0.15)))
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .sensoryFeedback(.selection, trigger: active)
    }
}

private struct QueueRow: View {
    let track: Item

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(item: track, points: 44, cornerRadius: 5)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artistLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
