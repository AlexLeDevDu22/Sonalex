import AVKit
import MediaPlayer
import SwiftUI

struct NowPlayingView: View {
    enum Mode { case artwork, lyrics, queue }

    @Environment(PlayerManager.self) private var player
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AmbilightClient.self) private var ambi
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .artwork
    @State private var palette = ArtworkPalette.fallback
    @Namespace private var artNamespace

    var body: some View {
        GeometryReader { geo in
            let track = player.current
            if geo.size.width > 900 {
                wideLayout(track, geo: geo)
            } else {
            VStack(spacing: 0) {
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .onTapGesture { dismiss() }

                if mode == .artwork {
                    bigArtwork(track, geo: geo)
                        .frame(maxHeight: .infinity)
                    titleRow(track)
                        .padding(.bottom, 18)
                } else {
                    compactHeader(track)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    Group {
                        if mode == .lyrics, let track {
                            LyricsView(track: track)
                        } else {
                            QueueView()
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                    .padding(.horizontal, -28)
                }

                controls
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 4)
            }
            .padding(.horizontal, 28)
            .frame(width: geo.size.width)
            .padding(.top, geo.safeAreaInsets.top)
            .ignoresSafeArea()
            }
        }
        .foregroundStyle(.white)
        .background {
            // Behind the controls, on top of the artwork colors.
            ZStack {
                NowPlayingBackground(palette: palette)
                AmbientGlowOverlay()
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(false)
        .task(id: player.current?.id) {
            let p = await ArtworkPalette.load(JellyfinClient.shared.artURL(player.current, points: 200))
            withAnimation(.easeInOut(duration: 0.8)) { palette = p }
        }
        .onChange(of: player.current == nil) { _, empty in if empty { dismiss() } }
        // Presented from here while Now Playing is open: the app's root can't show a sheet under it.
        .addToPlaylistPresenter(inNowPlaying: true)
        #if targetEnvironment(macCatalyst)
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(20)
        }
        #endif
    }

    // MARK: Wide screens (Mac, iPad)

    /// Artwork and controls on the left, lyrics (or the queue) always visible on the right.
    private func wideLayout(_ track: Item?, geo: GeometryProxy) -> some View {
        HStack(spacing: 56) {
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                bigArtwork(track, side: min(420, geo.size.height * 0.46))
                titleRow(track)
                    .padding(.top, 28)
                    .padding(.bottom, 18)
                controls(compact: false)
                Spacer(minLength: 16)
            }
            .frame(width: 440)

            Group {
                if mode == .queue {
                    QueueView()
                } else if let track {
                    LyricsView(track: track)
                }
            }
            .frame(maxWidth: 640, maxHeight: .infinity)
            .transition(.opacity)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(width: geo.size.width, height: geo.size.height)
    }

    // MARK: Artwork

    private func bigArtwork(_ track: Item?, geo: GeometryProxy) -> some View {
        bigArtwork(track, side: min(geo.size.width - 56, geo.size.height * 0.42))
    }

    private func bigArtwork(_ track: Item?, side: CGFloat) -> some View {
        MixArtworkSwap(incoming: track, outgoing: player.mixOutgoing, progress: player.mixProgress, side: side)
            .overlay {
                // Online song still being fetched by the Pi.
                if player.isBuffering {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(18)
                        .background(.ultraThinMaterial, in: Circle())
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: player.isBuffering)
            .matchedGeometryEffect(id: "art", in: artNamespace)
            .frame(width: side, height: side)
            .scaleEffect(player.isPlaying ? 1 : 0.78)
            .shadow(color: .black.opacity(player.isPlaying ? 0.4 : 0.2), radius: player.isPlaying ? 30 : 14,
                    y: player.isPlaying ? 18 : 8)
            .animation(.spring(response: 0.55, dampingFraction: 0.62), value: player.isPlaying)
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { v in
                    if v.translation.width < -60 { player.next() }
                    else if v.translation.width > 60 { player.previous() }
                }
            )
    }

    private func titleRow(_ track: Item?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let track, MomentFavorite.shared.isMoment(track) {
                    Label("Your Song of the Moment", systemImage: "flame.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                }
                MarqueeText(text: track?.title ?? "", font: .title3.weight(.bold))
                ArtistLink(track: track) {
                    Text(track?.artistLine ?? "")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let track { trailingButtons(track) }
        }
    }

    private func compactHeader(_ track: Item?) -> some View {
        HStack(spacing: 14) {
            ArtworkView(item: track, points: 64, cornerRadius: 6)
                .matchedGeometryEffect(id: "art", in: artNamespace)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .onTapGesture { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { mode = .artwork } }
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "").font(.headline).lineLimit(1)
                Text(track?.artistLine ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let track { trailingButtons(track) }
        }
    }

    private func trailingButtons(_ track: Item) -> some View {
        HStack(spacing: 12) {
            let fav = favorites.isFavorite(track)
            Button { favorites.toggle(track) } label: {
                Image(systemName: fav ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.15), in: Circle())
            }
            Menu {
                ItemMenu(item: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.15), in: Circle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Controls

    /// In the queue, controls shrink to one row (lyrics · ⏮ ⏯ ⏭ · queue) to give the list more room.
    private var controls: some View { controls(compact: mode == .queue) }

    private func controls(compact: Bool) -> some View {
        VStack(spacing: 0) {
            RemotePlaybackBadge(color: .white.opacity(0.85))
                .padding(.bottom, 8)
            ScrubberView(compact: compact)
                .padding(.bottom, compact ? 2 : 8)
            HStack(spacing: 0) {
                if compact { modeButton(.lyrics, on: "quote.bubble.fill", off: "quote.bubble") }
                TransportControls(compact: compact)
                if compact { modeButton(.queue, on: "list.bullet", off: "list.bullet") }
            }
            .padding(.vertical, compact ? 2 : 12)
            if !compact {
                VolumeSliderRow()
                    .padding(.top, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                bottomBar
                    .padding(.top, 20)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            modeButton(.lyrics, on: "quote.bubble.fill", off: "quote.bubble")
            Spacer()
            AirPlayButton()
                .frame(width: 44, height: 44)
            DevicePickerButton()
            if ambi.reachable && ambi.isPaired {
                Spacer()
                lightsButton
            }
            Spacer()
            modeButton(.queue, on: "list.bullet", off: "list.bullet")
        }
        .padding(.horizontal, 20)
    }

    /// One tap: "Lumières sur la musique" on the Mac's Ambilight.
    private var lightsButton: some View {
        let on = ambi.musicActive
        return Button { ambi.setMusicMode(!on) } label: {
            Image(systemName: on ? "lightbulb.led.fill" : "lightbulb.led")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(on ? Color.black.opacity(0.75) : Color.white.opacity(0.75))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(on ? 0.9 : 0)))
                .symbolEffect(.bounce, value: on)
        }
        .buttonStyle(PressableStyle(scale: 0.88))
        .sensoryFeedback(.impact(weight: .medium), trigger: on)
        .transition(.scale.combined(with: .opacity))
    }

    private func modeButton(_ target: Mode, on: String, off: String) -> some View {
        let active = mode == target
        return Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { mode = active ? .artwork : target }
        } label: {
            Image(systemName: active ? on : off)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(active ? Color.black.opacity(0.75) : Color.white.opacity(0.75))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(active ? 0.9 : 0)))
        }
        .buttonStyle(PressableStyle(scale: 0.88))
        // Same id in the bottom bar and in the compact row, so the button glides between them.
        .matchedGeometryEffect(id: "modeButton.\(target)", in: artNamespace)
    }
}

// MARK: - Artist link

/// Tapping the artist line: one artist → their page; several (featurings) → pick which one.
struct ArtistLink<Content: View>: View {
    let track: Item?
    @ViewBuilder let label: Content

    var body: some View {
        let artists = track?.artistItems ?? track?.albumArtists ?? []
        if artists.count > 1 {
            Menu {
                ForEach(artists, id: \.id) { a in
                    Button(a.name ?? "") { AppRouter.shared.open(Item.artistRoute(a)) }
                }
            } label: { label }
        } else {
            Button {
                if let a = artists.first { AppRouter.shared.open(Item.artistRoute(a)) }
            } label: { label }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Background

struct NowPlayingBackground: View {
    let palette: ArtworkPalette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = Float(ctx.date.timeIntervalSinceReferenceDate)
            MeshGradient(width: 3, height: 3, points: points(t), colors: palette.colors, smoothsColors: true)
        }
        .overlay(Color.black.opacity(0.12))
        .ignoresSafeArea()
    }

    private func points(_ t: Float) -> [SIMD2<Float>] {
        func wave(_ speed: Float, _ phase: Float, _ amp: Float) -> Float { 0.5 + sin(t * speed + phase) * amp }
        let top = SIMD2<Float>(wave(0.35, 0, 0.2), 0)
        let left = SIMD2<Float>(0, wave(0.3, 1, 0.2))
        let center = SIMD2<Float>(wave(0.4, 2, 0.22), wave(0.33, 3, 0.22))
        let right = SIMD2<Float>(1, wave(0.28, 4, 0.2))
        let bottom = SIMD2<Float>(wave(0.32, 5, 0.2), 1)
        return [SIMD2<Float>(0, 0), top, SIMD2<Float>(1, 0),
                left, center, right,
                SIMD2<Float>(0, 1), bottom, SIMD2<Float>(1, 1)]
    }
}

// MARK: - Scrubber

struct ScrubberView: View {
    var compact = false

    @Environment(PlayerManager.self) private var player
    @State private var dragProgress: Double? = nil
    @State private var dragStart: Double = 0

    var body: some View {
        let duration = max(player.duration, 0.1)
        let progress = dragProgress ?? min(max(player.currentTime / duration, 0), 1)
        let active = dragProgress != nil

        VStack(spacing: compact ? 3 : 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(active ? 1 : 0.7))
                        .frame(width: max(0, geo.size.width * progress))
                }
                .frame(height: active ? (compact ? 9 : 11) : (compact ? 5 : 7))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if dragProgress == nil {
                                dragStart = progress
                                player.isScrubbing = true
                            }
                            let delta = v.translation.width / max(geo.size.width, 1)
                            dragProgress = min(max(dragStart + delta, 0), 1)
                        }
                        .onEnded { _ in
                            if let p = dragProgress { player.seek(to: p * duration) }
                            dragProgress = nil
                            player.isScrubbing = false
                        }
                )
            }
            .frame(height: compact ? 18 : 24)
            .scaleEffect(x: active ? 1.03 : 1, y: 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)

            HStack {
                Text(Format.time(progress * duration))
                Spacer()
                if player.isBuffering {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                Spacer()
                Text("-" + Format.time(max(0, duration - progress * duration)))
            }
            .font((compact ? Font.caption2 : Font.caption).monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(active ? 0.9 : 0.5))
        }
        .sensoryFeedback(.selection, trigger: active)
    }
}

// MARK: - Transport

struct TransportControls: View {
    var compact = false

    @Environment(PlayerManager.self) private var player
    @State private var backTaps = 0
    @State private var nextTaps = 0

    var body: some View {
        let scale: CGFloat = compact ? 0.62 : 1
        HStack {
            Spacer(minLength: 0)
            Button {
                backTaps += 1
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 32))
                    .symbolEffect(.bounce.down, value: backTaps)
                    .scaleEffect(scale)
                    .frame(width: compact ? 56 : 80, height: compact ? 48 : 64)
            }
            Spacer(minLength: 0)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .scaleEffect(scale)
                    .frame(width: compact ? 64 : 90, height: compact ? 52 : 72)
            }
            Spacer(minLength: 0)
            Button {
                nextTaps += 1
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 32))
                    .symbolEffect(.bounce.down, value: nextTaps)
                    .scaleEffect(scale)
                    .frame(width: compact ? 56 : 80, height: compact ? 48 : 64)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(CircleHighlightStyle(diameter: compact ? 50 : 76))
        .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
    }
}

/// Apple's transport buttons: a soft circle appears behind the symbol while pressed.
struct CircleHighlightStyle: ButtonStyle {
    var diameter: CGFloat = 76

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.15 : 0)).frame(width: diameter, height: diameter))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Volume & AirPlay (system controls)

struct VolumeSliderRow: View {
    @Environment(PlayerManager.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            #if targetEnvironment(macCatalyst)
            Slider(value: Binding(get: { player.controlledVolume }, set: { player.setVolume($0) }), in: 0...1)
                .tint(.white)
            #else
            SystemVolumeSlider().frame(height: 34)
            #endif
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.55))
    }
}

#if !targetEnvironment(macCatalyst)
/// MPVolumeView drives the real device volume (hardware buttons stay in sync).
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.setVolumeThumbImage(Self.thumb(), for: .normal)
        view.tintColor = .white
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = .white.withAlphaComponent(0.85)
            slider.maximumTrackTintColor = .white.withAlphaComponent(0.22)
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    private static func thumb() -> UIImage {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }
}

#endif

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.75)
        view.activeTintColor = UIColor(Color.appAccent)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Marquee

/// Scrolls long titles horizontally, like Apple Music.
struct MarqueeText: View {
    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var animate = false

    var body: some View {
        let overflow = textWidth > containerWidth + 1
        // The layout size comes from a one-line, truncating copy; the scrolling copy lives in an
        // overlay so its full width can never push the rest of the screen sideways.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .offset(x: overflow && animate ? -(textWidth - containerWidth + 24) : 0)
                    .animation(overflow && animate
                               ? .linear(duration: Double(textWidth - containerWidth) / 30 + 1).delay(2.5)
                                   .repeatForever(autoreverses: true)
                               : .default, value: animate)
            }
            .clipped()
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: overflow ? 8 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: overflow ? 16 : 0)
                }
            )
            .task(id: text) {
                animate = false
                try? await Task.sleep(for: .milliseconds(300))
                animate = true
            }
    }
}


/// Mix: while both songs are heard, the covers swap like two cards — the old one slides away to
/// the left, turning and fading, the new one comes in from the right — following the blend.
struct MixArtworkSwap: View {
    let incoming: Item?
    let outgoing: Item?
    let progress: Double?
    let side: CGFloat

    var body: some View {
        let mixing = progress != nil && outgoing != nil
        let p = mixing ? min(max(progress ?? 1, 0), 1) : 1
        // Ease the motion: slow start and end, like a crossfader.
        let e = p * p * (3 - 2 * p)
        ZStack {
            if mixing, let outgoing {
                ArtworkView(item: outgoing, points: 360, cornerRadius: 12)
                    .frame(width: side, height: side)
                    .scaleEffect(1 - 0.24 * e)
                    .rotation3DEffect(.degrees(24 * e), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .offset(x: -side * 0.46 * e)
                    .opacity(1 - 0.95 * e)
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                    .zIndex(1 - e)
            }
            ArtworkView(item: incoming, points: 360, cornerRadius: 12)
                .frame(width: side, height: side)
                .scaleEffect(mixing ? 0.76 + 0.24 * e : 1)
                .rotation3DEffect(.degrees(mixing ? -24 * (1 - e) : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .offset(x: mixing ? side * 0.46 * (1 - e) : 0)
                .opacity(mixing ? 0.25 + 0.75 * e : 1)
                .zIndex(e)
        }
        .frame(width: side, height: side)
        .animation(.linear(duration: 0.15), value: progress)
        .overlay(alignment: .bottom) {
            if mixing, let outgoing {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text(outgoing.title).lineLimit(1)
                        Image(systemName: "arrow.right").font(.caption2.weight(.heavy))
                        Text(incoming?.title ?? "").lineLimit(1)
                    }
                    .font(.caption.weight(.bold))
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.25))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: geo.size.width * p)
                            }
                    }
                    .frame(height: 3)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: side * 0.86)
                .background(.ultraThinMaterial, in: Capsule())
                .offset(y: 22)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: mixing)
    }
}
