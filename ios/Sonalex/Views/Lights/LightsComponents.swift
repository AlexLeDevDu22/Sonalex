import SwiftUI
import UIKit

extension Color {
    init(ambiHex hex: String) {
        if let c = AmbiColor.rgb(hex) { self.init(red: c.0, green: c.1, blue: c.2) } else { self = .gray }
    }

    var ambiHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return AmbiColor.hex(r: Double(r), g: Double(g), b: Double(b))
    }
}

// MARK: - LED strip preview

/// A screen outline ringed by the 32 LEDs of `leds.preview` (bottom-left, counter-clockwise).
struct LEDStripPreview: View {
    let preview: String?
    var running = true

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = AmbiColor.strip(preview)
        let dark = scheme == .dark
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 16, dy: 16)
            let screen = rect.insetBy(dx: 12, dy: 12)
            let n = colors.isEmpty ? 32 : colors.count
            let w = rect.width, h = rect.height
            let perimeter = 2 * (w + h)
            func position(_ i: Int) -> CGPoint {
                let d = (Double(i) + 0.5) / Double(n) * perimeter
                if d < w { return CGPoint(x: rect.minX + d, y: rect.maxY) }
                if d < w + h { return CGPoint(x: rect.maxX, y: rect.maxY - (d - w)) }
                if d < 2 * w + h { return CGPoint(x: rect.maxX - (d - w - h), y: rect.minY) }
                return CGPoint(x: rect.minX, y: rect.minY + (d - 2 * w - h))
            }

            let screenPath = Path(roundedRect: screen, cornerRadius: 10)
            ctx.fill(screenPath, with: .color(dark ? Color(white: 0.12) : Color(white: 0.9)))
            // Light spilling onto the screen from its edges, like the real thing on the wall.
            if running, !colors.isEmpty {
                ctx.drawLayer { layer in
                    layer.clip(to: screenPath)
                    layer.addFilter(.blur(radius: 16))
                    let center = CGPoint(x: screen.midX, y: screen.midY)
                    for i in 0..<n where i < colors.count {
                        let p = position(i)
                        let q = CGPoint(x: p.x + (center.x - p.x) * 0.12, y: p.y + (center.y - p.y) * 0.12)
                        let c = colors[i]
                        layer.fill(Path(ellipseIn: CGRect(x: q.x - 26, y: q.y - 26, width: 52, height: 52)),
                                   with: .color(Color(red: c.0, green: c.1, blue: c.2).opacity(0.55)))
                    }
                }
            }
            ctx.stroke(screenPath, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)

            for i in 0..<n {
                let p = position(i)

                let color: Color
                if running, i < colors.count {
                    let c = colors[i]
                    color = Color(red: c.0, green: c.1, blue: c.2)
                } else {
                    color = Color(white: 0.25)
                }
                if running && !colors.isEmpty {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)), with: .color(color.opacity(0.22)))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(color.opacity(0.35)))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(color))
            }
        }
        .aspectRatio(16 / 10.5, contentMode: .fit)
    }
}

// MARK: - Mouse preview

struct MousePreview: View {
    let preview: AmbiLive.MousePreview?
    var running = true

    var body: some View {
        let off = Color(white: 0.25)
        let ring = preview?.ring
        let wheel = running ? preview?.wheel.map { Color(ambiHex: $0) } ?? off : off
        let logo = running ? preview?.logo.map { Color(ambiHex: $0) } ?? off : off

        TimelineView(.animation(minimumInterval: 1 / 15, paused: !(running && ring?.type == "flow"))) { ctx in
            let angle = ringAngle(ring, t: ctx.date.timeIntervalSinceReferenceDate)
            ZStack {
                Capsule()
                    .fill(Color(white: 0.09))
                Capsule()
                    .strokeBorder(ringStyle(ring, angle: angle), lineWidth: 3)
                    .shadow(color: (ringColors(ring).first ?? off).opacity(running ? 0.6 : 0), radius: 8)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(wheel)
                    .frame(width: 5, height: 13)
                    .shadow(color: wheel.opacity(running ? 0.8 : 0), radius: 4)
                    .offset(y: -20)
                Image(systemName: "seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(logo)
                    .shadow(color: logo.opacity(running ? 0.8 : 0), radius: 4)
                    .offset(y: 16)
            }
            .frame(width: 46, height: 74)
        }
    }

    private func ringColors(_ ring: AmbiLive.Ring?) -> [Color] {
        guard running, let ring else { return [Color(white: 0.25)] }
        if ring.type == "flow", let colors = ring.colors, colors.count > 1 { return colors.map { Color(ambiHex: $0) } }
        if let c = ring.color { return [Color(ambiHex: c)] }
        return [Color(white: 0.25)]
    }

    private func ringStyle(_ ring: AmbiLive.Ring?, angle: Double) -> AnyShapeStyle {
        let colors = ringColors(ring)
        if colors.count > 1 {
            return AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center, angle: .degrees(angle)))
        }
        return AnyShapeStyle(colors[0])
    }

    /// `speed` 0 = fast … 15 = slow.
    private func ringAngle(_ ring: AmbiLive.Ring?, t: TimeInterval) -> Double {
        guard let ring, ring.type == "flow" else { return 0 }
        let period = 1.5 + (ring.speed ?? 5) * 0.6
        let a = (t.truncatingRemainder(dividingBy: period) / period) * 360
        return ring.cw == false ? -a : a
    }
}

// MARK: - Small pieces

/// 7-band equalizer fed by `levels`.
struct LevelBars: View {
    let levels: [Double]
    var color: Color = .white

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 3 + 15 * CGFloat(i < levels.count ? min(max(levels[i], 0), 1) : 0))
            }
        }
        .frame(height: 18, alignment: .bottom)
        .animation(.linear(duration: 0.07), value: levels)
    }
}

struct PaletteSwatch: View {
    let palette: AmbiPalette
    let selected: Bool
    var cover: Item?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if palette.id == "cover" {
                    ArtworkView(item: cover, points: 44, circle: true)
                } else {
                    let colors = (palette.colors ?? []).map { Color(ambiHex: $0) }
                    Circle().fill(AngularGradient(colors: colors.isEmpty ? [.gray] : colors + [colors[0]], center: .center))
                }
            }
            .frame(width: 44, height: 44)
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2.5))
            .scaleEffect(selected ? 1.05 : 1)
            Text(palette.label ?? palette.id)
                .font(.caption2.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .frame(width: 60)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
    }
}

struct EffectChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(selected ? Color.primary : Color(.tertiarySystemFill)))
        }
        .buttonStyle(PressableStyle(scale: 0.94))
    }
}

/// Dark rounded card used across the Lights page.
struct LightsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ConnectionPill: View {
    @Environment(AmbilightClient.self) private var ambi

    var body: some View {
        let (color, text): (Color, String) = switch ambi.connection {
        case .online: (.green, ambi.macName)
        case .reconnecting: (.orange, "Reconnexion…")
        case .searching: (.orange, "Recherche…")
        case .offline: (.gray, "Hors ligne")
        }
        Button { ambi.retry() } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(text).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .disabled(ambi.connection == .online)
    }
}

// MARK: - Ambient glow ("magic" light at the bottom while the lights follow the music)

struct AmbientGlowOverlay: View {
    @Environment(AmbilightClient.self) private var ambi
    @Environment(PlayerManager.self) private var player
    @State private var artColors: [Color] = []

    var body: some View {
        let active = ambi.isStreamingMusic
        ZStack {
            if active {
                AmbientGlow(colors: glowColors)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1), value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: player.current?.id) {
            let p = await ArtworkPalette.load(JellyfinClient.shared.artURL(player.current, points: 100))
            // Brightest, most saturated cells of the 3×3 artwork grid.
            artColors = [p.colors[4], p.colors[0], p.colors[8], p.colors[2]]
        }
    }

    private var glowColors: [Color] {
        let c = ambi.paletteColors ?? artColors
        return c.isEmpty ? [.purple, .blue, .pink] : c
    }
}

/// Edge glow hugging the bottom of the screen: the LED colors blend into each other in place
/// (no sweeping), the band swells with the bass and brightens with the volume.
struct AmbientGlow: View {
    let colors: [Color]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let meter = AmbilightAudioSink.shared.meter()
            let gradient = LinearGradient(stops: stops(t), startPoint: .leading, endPoint: .trailing)
            ZStack(alignment: .bottom) {
                // Soft halo.
                Rectangle()
                    .fill(gradient)
                    .frame(height: 46 + 38 * meter.1)
                    .blur(radius: 26)
                    .opacity(0.45 + 0.4 * meter.0)
                // Bright line right on the edge.
                Rectangle()
                    .fill(gradient)
                    .frame(height: 5 + 5 * meter.1)
                    .blur(radius: 5)
                    .opacity(0.55 + 0.45 * meter.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: 12)
        }
        .frame(height: 110)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
        .blendMode(scheme == .dark ? .plusLighter : .normal)
        .opacity(scheme == .dark ? 0.95 : 0.7)
        .ignoresSafeArea()
    }

    /// Color stops that drift gently around their place, so hues melt into one another.
    private func stops(_ t: TimeInterval) -> [Gradient.Stop] {
        let base = colors.isEmpty ? [Color.purple, .blue] : colors
        let cycle = base + [base[0]]
        let n = cycle.count
        let spacing = 1 / Double(n - 1)
        var last = -1.0
        return cycle.enumerated().map { i, color in
            var loc = Double(i) * spacing
            if i > 0 && i < n - 1 { loc += sin(t * 0.35 + Double(i) * 1.9) * spacing * 0.35 }
            loc = max(loc, last + 0.001)
            last = loc
            return Gradient.Stop(color: color, location: min(loc, 1))
        }
    }
}
