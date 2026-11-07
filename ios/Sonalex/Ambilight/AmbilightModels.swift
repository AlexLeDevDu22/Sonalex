import Foundation

// Every field is optional: the Mac server may evolve, the app must keep decoding.

struct AmbiInfo: Decodable, Equatable {
    var name: String?
    var apiVersion: Int?
    var computer: String?
    var paired: Bool?
    var devices: Devices?

    struct Devices: Decodable, Equatable {
        var leds: Bool?
        var mouse: Bool?
    }
}

struct AmbiOption: Decodable, Hashable, Identifiable {
    var id: String
    var label: String?

    var title: String { label ?? id }
}

struct AmbiPalette: Decodable, Hashable, Identifiable {
    var id: String
    var label: String?
    var colors: [String]?
}

struct AmbiCatalog: Decodable, Equatable {
    var leds: Leds?
    var mouse: Mouse?
    var palettes: [AmbiPalette]?

    struct Leds: Decodable, Equatable {
        var modes: [AmbiOption]?
        var soundEffects: [AmbiOption]?
        var ambientEffects: [AmbiOption]?
    }

    struct Mouse: Decodable, Equatable {
        var modes: [AmbiOption]?
        var soundEffects: [AmbiOption]?
    }
}

struct AmbiConfig: Decodable, Equatable {
    var leds: Leds?
    var mouse: Mouse?
    var general: General?

    struct Leds: Decodable, Equatable {
        var mode: String?
        var soundEffect: String?
        var ambientEffect: String?
        var palette: String?
        var brightness: Double?
        var sensitivity: Double?
        var speed: Double?
        var smoothing: Double?
        var letterbox: Bool?
        var colors: [String]?
    }

    struct Mouse: Decodable, Equatable {
        var mode: String?
        var soundEffect: String?
        var palette: String?
        var brightness: Double?
        var sensitivity: Double?
        var speed: Double?
        var responsive: Bool?
    }

    struct General: Decodable, Equatable {
        var smartSleep: Bool?
        var lan: Bool?
    }
}

struct AmbiLive: Decodable, Equatable {
    var leds: Leds?
    var mouse: Mouse?
    var nowplaying: NowPlaying?
    var audio: Audio?
    var levels: [Double]?
    var remote: Remote?
    var sleep: Sleep?
    var cfg: Int?

    struct Leds: Decodable, Equatable {
        var running: Bool?
        var mode: String?
        var status: String?
        var preview: String?
        var palette: [String]?
    }

    struct Mouse: Decodable, Equatable {
        var running: Bool?
        var mode: String?
        var status: String?
        var preview: MousePreview?
        var palette: [String]?
    }

    struct MousePreview: Decodable, Equatable {
        var ring: Ring?
        var wheel: String?
        var logo: String?
    }

    struct Ring: Decodable, Equatable {
        var type: String?
        var color: String?
        var colors: [String]?
        var speed: Double?
        var cw: Bool?
    }

    struct NowPlaying: Decodable, Equatable {
        var playing: Bool?
        var track: String?
        var artist: String?
        var album: String?
        var cover: String?
        var colors: [String]?
        var source: String?
    }

    struct Audio: Decodable, Equatable {
        var source: String?
        var networkClient: String?
    }

    struct Remote: Decodable, Equatable {
        var id: Int?
        var text: String?
    }

    struct Sleep: Decodable, Equatable {
        var on: Bool?
        var reason: String?
    }
}

struct AmbiState: Decodable {
    var config: AmbiConfig?
    var catalog: AmbiCatalog?
    var live: AmbiLive?
}

enum AmbiColor {
    /// "#rrggbb" → (r, g, b) in 0…1.
    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    /// The `leds.preview` string: 32 colors of 6 hex characters each.
    static func strip(_ preview: String?) -> [(Double, Double, Double)] {
        guard let preview else { return [] }
        let chars = Array(preview.utf8)
        var out: [(Double, Double, Double)] = []
        out.reserveCapacity(chars.count / 6)
        var i = 0
        while i + 6 <= chars.count {
            if let s = String(bytes: chars[i..<(i + 6)], encoding: .ascii), let c = rgb(s) { out.append(c) }
            i += 6
        }
        return out
    }

    static func hex(r: Double, g: Double, b: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }
}
