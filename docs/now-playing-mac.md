# Sonalex (Mac) → "now playing" and device choice for another app (e.g. Atoll)

**Sonalex** runs on the iPhone and on the Mac (Mac Catalyst). With **Sonalex Connect**, only one
device plays at a time; the others mirror what it plays and control it. So on the Mac, the app
always publishes **what's playing on any of the devices**, and accepts commands it runs or
forwards to the playing device.

An app like **Atoll** only needs to talk to the Mac app:

| Atoll wants to… | How |
|---|---|
| know what's playing (title, artwork, position), even on the iPhone | read `NowPlaying.json` on each Darwin notification (§2) |
| play / pause / next / previous, even when the iPhone plays | open `sonalex://…` (§3) |
| show the devices (Mac, iPhone) and which one plays | the `connect` block of the JSON (§2) |
| play on the Mac or on the iPhone | `sonalex://transfer?device=<id>` (§3) |

---

## 1. macOS's standard "Now Playing"

The Mac app fills in `MPNowPlayingInfoCenter` (title, artist, album, artwork, duration, position,
rate) and `playbackState`, including when the iPhone plays. It also answers system commands:
media keys, Control Center, `MRMediaRemoteSendCommand`. These commands are forwarded to the playing
device.

An app reading the system Now Playing through MediaRemote (since macOS 15.4, through an adapter
like [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter)) therefore sees Sonalex.
But that channel **can't** choose the device: that's what §2 and §3 are for.

## 2. `NowPlaying.json` + Darwin notification

On every change (song, play/pause, seek, playing device, device connected or disconnected) and
every ~5 s while playing, the Mac app rewrites, **atomically**:

```
~/Library/Application Support/Musique/NowPlaying.json
```

(The folder kept the app's former name, so existing integrations keep working. In the App Store
version, sandboxed, it's inside the app's container:
`~/Library/Containers/com.alexgarin.sonalex/Data/Library/Application Support/Musique/`.)

Right after, it posts the **Darwin notification** `com.alexgarin.musique.nowplaying`.

```json
{
  "title": "TORE UP",
  "artist": "Don Toliver",
  "album": "HARDSTONE PSYCHO",
  "artworkURL": "https://jellyfin.example.com/Items/fc41e7…/Images/Primary?fillWidth=600&fillHeight=600&quality=90&tag=…",
  "duration": 127.0,
  "elapsed": 42.3,
  "isPlaying": true,
  "source": "library",
  "id": "6da3d3585a7d641ee9c4a8386b8e8159",
  "updatedAt": 1790950000.12,
  "bundleId": "maccatalyst.com.alexgarin.sonalex",
  "connect": {
    "available": true,
    "thisDevice": "6F1C…-MAC",
    "playingOn": "A93B…-IPHONE",
    "isRemote": true,
    "devices": [
      { "id": "6F1C…-MAC",    "name": "MacBook Air", "kind": "mac",   "isThisDevice": true,  "isPlaying": false },
      { "id": "A93B…-IPHONE", "name": "iPhone",      "kind": "phone", "isThisDevice": false, "isPlaying": true }
    ]
  }
}
```

| Field | Description |
|---|---|
| `title`, `artist`, `album` | What's playing, on this Mac **or on the playing device**. Missing if nothing is loaded. |
| `artworkURL` | JPEG (Jellyfin or an online catalog's CDN), downloadable without authentication. |
| `duration`, `elapsed` | In seconds. Real position = `elapsed + (now - updatedAt)` if `isPlaying`. |
| `isPlaying` | Playback wanted (here or on the playing device): stays `true` while loading or changing the audio output, `false` only after a real pause, the end of the queue or an error. |
| `source` | `"library"` (Jellyfin) or `"online"` (a song of the server's online catalog). |
| `id` | The song's id; it changes with every new song. |
| `connect.available` | The Mac app is connected to the Sonalex server. If `false`, the device list is empty. |
| `connect.thisDevice` | The Mac's own id. |
| `connect.playingOn` | The playing device's id. Empty if nothing plays anywhere. |
| `connect.isRemote` | `true` if **another** device than the Mac plays. |
| `connect.devices` | Connected devices: `id`, `name` (e.g. "Emma's iPhone", editable in the app: profile → Name of This Device), `kind` (`mac`, `phone`, `tablet`), `volume` (0…1, the app's playback volume on that device), `isThisDevice`, `isPlaying`. |

If `updatedAt` is more than 10 s old while `isPlaying` is `true`, the Mac app is closed: there's no
Sonalex source anymore.

## 3. Commands: `sonalex://`

`musique://…` (the former name) still works.

| URL | Effect |
|---|---|
| `sonalex://playpause` | play / pause (on the playing device) |
| `sonalex://play`, `sonalex://pause` | play, pause |
| `sonalex://next`, `sonalex://previous` | next / previous song |
| `sonalex://open` | shows the Mac app's Now Playing screen |
| `sonalex://transfer?device=<id>` | plays on device `<id>`, taken from `connect.devices` |
| `sonalex://volume?level=0.42` | playback volume (0…1) of the playing device, forwarded if it's another one; kept on a transfer |
| `sonalex://transfer?device=this` | plays on this Mac |
| `sonalex://transfer?kind=phone` | plays on the iPhone (the first `phone` device); `kind=mac` for the Mac |

A transfer resumes **at the same point of the same song**, with the same queue. The device that
was playing stops. The JSON is rewritten as soon as the server confirms (a few tenths of a second).

Open these URLs **without bringing Sonalex to the front**:

```swift
func sonalex(_ command: String) {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    NSWorkspace.shared.open(URL(string: "sonalex://\(command)")!, configuration: config)
}
sonalex("next")
sonalex("transfer?kind=phone")
```

### 3b. Commands without URLs (recommended for Atoll)

`sonalex://` URLs depend on macOS knowing which app opens them. With a development build it
sometimes forgets ("There is no application set to open the URL"). This channel goes straight to
the Mac app, when it's open:

1. Write `~/Library/Application Support/Musique/Command.json`:
   ```json
   { "id": "<unique id, e.g. a UUID>", "command": "pause" }
   ```
   `command` accepts `play`, `pause`, `playpause`, `next`, `previous`, `open`,
   `volume` (with `"level": 0.42`) and `transfer` (with `"device": "<id>"` or `"this"`, or
   `"kind": "phone"`). The `id` must change with every command, otherwise it's ignored.
2. Post the Darwin notification `com.alexgarin.musique.command`.

```swift
func sonalexCommand(_ command: String, extra: [String: Any] = [:]) {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Musique/Command.json")
    var body = extra
    body["id"] = UUID().uuidString
    body["command"] = command
    if let data = try? JSONSerialization.data(withJSONObject: body) {
        try? data.write(to: url, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.alexgarin.musique.command" as CFString), nil, nil, true)
    }
}
sonalexCommand("pause")
sonalexCommand("volume", extra: ["level": 0.42])
sonalexCommand("transfer", extra: ["kind": "phone"])
```

Tip: use this channel while the Mac app runs (the JSON's `updatedAt` is recent), and `sonalex://`
URLs only to launch the app when it's closed.

## 4. Reading it in Atoll (Swift)

```swift
import AppKit

struct SonalexDevice: Decodable, Identifiable {
    let id: String; let name: String; let kind: String
    let isThisDevice: Bool; let isPlaying: Bool
}

struct SonalexNowPlaying: Decodable {
    struct Connect: Decodable {
        let available: Bool; let thisDevice: String; let playingOn: String
        let isRemote: Bool; let devices: [SonalexDevice]
    }
    let title: String?; let artist: String?; let album: String?
    let artworkURL: String?; let duration: Double; let elapsed: Double
    let isPlaying: Bool; let updatedAt: Double; let id: String?
    let connect: Connect?

    /// Current position, moved forward since the last write.
    var position: Double {
        isPlaying ? min(duration, elapsed + Date().timeIntervalSince1970 - updatedAt) : elapsed
    }
}

final class SonalexSource {
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Musique/NowPlaying.json")
    var onChange: ((SonalexNowPlaying) -> Void)?

    func start() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<SonalexSource>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.reload() }
            },
            "com.alexgarin.musique.nowplaying" as CFString, nil, .deliverImmediately)
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(SonalexNowPlaying.self, from: data) else { return }
        onChange?(info)
    }

    func send(_ command: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(URL(string: "sonalex://\(command)")!, configuration: config)
    }

    func play(on device: SonalexDevice) { send("transfer?device=\(device.id)") }
}
```

## 5. The "device" button in Atoll

- Only show it if `connect.available` is `true` and `connect.devices` holds at least 2 devices.
- **Icon** (SF Symbols) by playing device (`isPlaying == true`): `laptopcomputer` for `mac`,
  `iphone` for `phone`, `ipad` for `tablet`. Use the accent color if `connect.isRemote` (the sound
  comes out of the iPhone, not the Mac).
- **On click**, a menu lists `connect.devices`: name ("This Mac" if `isThisDevice`), a check mark on
  the one playing. Picking one sends `sonalex://transfer?device=<id>`.
- **Shortcut**: a simple Mac ↔ iPhone toggle that sends `transfer?kind=phone` if the Mac plays,
  `transfer?device=this` otherwise.

---

## Instructions to give a Claude session on the Mac (for Atoll)

> Atoll is an open-source "Dynamic Island" app for the Mac. Its media controller handles Spotify.
> Add a **Sonalex** source (a Jellyfin music player, synced between my Mac and my iPhone)
> following `docs/now-playing-mac.md` of the sonalex repository:
> 1. Read `~/Library/Application Support/Musique/NowPlaying.json` at launch and on every Darwin
>    notification `com.alexgarin.musique.nowplaying`. Interpolate the position with
>    `elapsed + (now - updatedAt)` while playing.
> 2. Show the title, artist, artwork (`artworkURL`) and progress like for Spotify, **even when the
>    sound comes out of the iPhone** (`connect.isRemote`).
> 3. Send commands through `Command.json` + the Darwin notification
>    `com.alexgarin.musique.command` (§3b) while the Mac app runs; `sonalex://` URLs only to launch
>    it when it's closed.
> 4. Add a **device button** (§5): a menu of `connect.devices` with a check mark on the one playing;
>    a choice sends `sonalex://transfer?device=<id>`.
> 5. Give Sonalex priority when `isPlaying` is `true`; otherwise go back to the previous source
>    (Spotify). Treat the source as gone if `updatedAt` is more than 10 s old while playing.
> Follow Atoll's existing architecture (same protocol and same interface as the Spotify controller).
