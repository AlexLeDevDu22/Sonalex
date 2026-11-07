import AVFoundation
import SwiftUI
import UIKit

/// Square artwork with placeholder, fade-in and memory/disk cache. Fills its frame.
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    var circle = false
    var placeholder = "music.note"
    /// For artists: if Jellyfin has no photo, fall back on Deezer.
    var artistName: String? = nil
    var points: CGFloat = 100

    @State private var image: UIImage? = nil

    init(url: URL?, cornerRadius: CGFloat = 8, circle: Bool = false, placeholder: String? = nil,
         artistName: String? = nil, points: CGFloat = 100) {
        self.url = url
        self.cornerRadius = cornerRadius
        self.circle = circle
        self.artistName = artistName
        self.points = points
        self.placeholder = placeholder ?? (circle ? "music.microphone" : "music.note")
        _image = State(initialValue: ImageCache.shared.cached(url))
    }

    private var shape: AnyShape {
        circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    var body: some View {
        Color(.systemGray5)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                        // clipShape only clips the drawing: the spilled part of a scaled-to-fill
                        // photo would still take taps meant for the views around it.
                        .allowsHitTesting(false)
                } else {
                    GeometryReader { geo in
                        Image(systemName: placeholder)
                            .font(.system(size: max(12, geo.size.width * 0.34), weight: .regular))
                            .foregroundStyle(Color(.systemGray2))
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
            // Taps stay inside the frame: a scaled-to-fill image spills past it otherwise.
            .contentShape(shape)
            .overlay { shape.stroke(Color.primary.opacity(0.07), lineWidth: 0.5) }
            .task(id: url) {
                if let hit = ImageCache.shared.cached(url) { image = hit; return }
                var loaded: UIImage? = nil
                if let url { loaded = await ImageCache.shared.image(for: url) }
                if loaded == nil, let artistName,
                   let alt = await ArtistImages.shared.url(for: artistName, points: points) {
                    loaded = await ImageCache.shared.image(for: alt)
                }
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

extension ArtworkView {
    init(item: Item?, points: CGFloat, cornerRadius: CGFloat = 8, circle: Bool = false) {
        self.init(url: JellyfinClient.shared.artURL(item, points: points), cornerRadius: cornerRadius, circle: circle,
                  placeholder: item.map { i in
                      i.isArtist ? "music.microphone" : i.isPlaylist ? "music.note.list" : "music.note"
                  },
                  artistName: item?.isArtist == true ? item?.name : nil,
                  points: points)
    }
}

/// 3×3 grid of colors sampled from the artwork — feeds the animated mesh gradient behind Now Playing.
struct ArtworkPalette: Equatable {
    var colors: [Color]
    var average: Color

    static let fallback = ArtworkPalette(
        colors: Array(repeating: Color(white: 0.22), count: 9),
        average: Color(white: 0.22)
    )

    @MainActor
    static func load(_ url: URL?) async -> ArtworkPalette {
        guard let url, let image = await ImageCache.shared.image(for: url), let cg = image.cgImage else { return .fallback }
        return await Task.detached(priority: .userInitiated) { ArtworkPalette.compute(cg) }.value
    }

    nonisolated static func compute(_ cg: CGImage) -> ArtworkPalette {
        let n = 3
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return .fallback }

        var colors: [Color] = []
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        for i in 0..<(n * n) {
            var r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
            sum.r += r; sum.g += g; sum.b += b
            // Keep white text readable: cap brightness, add a touch of saturation.
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let target = min(lum, 0.42) / max(lum, 0.001)
            r *= target; g *= target; b *= target
            let gray = (r + g + b) / 3
            r = gray + (r - gray) * 1.25; g = gray + (g - gray) * 1.25; b = gray + (b - gray) * 1.25
            colors.append(Color(red: clamp(r), green: clamp(g), blue: clamp(b)))
        }
        let count = Double(n * n)
        let avg = Color(red: sum.r / count * 0.8, green: sum.g / count * 0.8, blue: sum.b / count * 0.8)
        return ArtworkPalette(colors: colors, average: avg)
    }

    nonisolated private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// "Now playing" bars: they follow the song actually playing on this device (4 frequency
/// bands from the player's audio tap); generic motion when the sound comes from elsewhere.
struct EqualizerBars: View {
    var animating: Bool
    var color: Color = .appAccent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { ctx in
            let t: Double = ctx.date.timeIntervalSinceReferenceDate
            let live = animating ? AmbilightAudioSink.shared.bands(localDelay: Self.outputDelay) : nil
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: 3, height: 14 * barHeight(i, t, live))
                }
            }
            .frame(width: 18, height: 14, alignment: .bottom)
            .foregroundStyle(color)
        }
    }

    static var outputDelay: TimeInterval {
        #if targetEnvironment(macCatalyst)
        return 0.05
        #else
        let s = AVAudioSession.sharedInstance()
        return min(max(s.outputLatency + s.ioBufferDuration, 0), 0.5)
        #endif
    }

    private func barHeight(_ i: Int, _ t: Double, _ live: [Double]?) -> CGFloat {
        let resting: [Double] = [0.45, 0.8, 0.6, 0.35]
        guard animating else { return CGFloat(resting[i]) }
        if let live, live.count == 4 {
            return CGFloat(0.12 + 0.88 * live[i])
        }
        let phase: Double = t * (5.5 + Double(i) * 1.3) + Double(i) * 1.7
        return CGFloat(0.3 + 0.7 * abs(sin(phase)))
    }
}
