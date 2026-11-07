import SwiftUI

extension Color {
    static let appAccent = Color(red: 124 / 255, green: 92 / 255, blue: 255 / 255)
}

enum Format {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func totalDuration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) h" : "\(h) hr \(m) min"
        }
        return minutes <= 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func songCount(_ n: Int) -> String {
        n == 1 ? "1 song" : "\(n) songs"
    }

    static func releaseDate(_ item: Item) -> String? {
        guard let raw = item.premiereDate ?? item.dateCreated else { return item.year.map(String.init) }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(raw.prefix(10))) else { return item.year.map(String.init) }
        return date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "en_US")))
    }
}

/// Deterministic pleasant color for tiles without artwork (genres…).
enum TileColor {
    private static let palette: [Color] = [
        Color(red: 0.93, green: 0.27, blue: 0.36), Color(red: 0.98, green: 0.55, blue: 0.20),
        Color(red: 0.36, green: 0.42, blue: 0.94), Color(red: 0.18, green: 0.67, blue: 0.58),
        Color(red: 0.62, green: 0.35, blue: 0.85), Color(red: 0.18, green: 0.55, blue: 0.86),
        Color(red: 0.85, green: 0.30, blue: 0.62), Color(red: 0.40, green: 0.62, blue: 0.25),
        Color(red: 0.78, green: 0.45, blue: 0.25), Color(red: 0.30, green: 0.35, blue: 0.50),
    ]

    static func color(for key: String) -> Color {
        var hash: UInt64 = 5381
        for b in key.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Scale-down press feedback used on cards and big buttons.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}
