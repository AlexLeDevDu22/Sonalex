<p align="center"><img src="docs/app-store/icon-1024.png" width="128" alt=""></p>

# Sonalex

**The music player for your [Jellyfin](https://jellyfin.org) server**, on iPhone, iPad and Mac.

Sonalex connects to **any Jellyfin server** with your usual account: there is no Sonalex account,
and nothing is sent anywhere but to your server.

| With Jellyfin alone | With the Sonalex server too (optional) |
|---|---|
| Home, new releases, library (artists, albums, songs, favorites, genres, playlists) | **Mix**: DJ-style transitions between songs (beat-matched, never over a voice) |
| Full-screen player, synced lyrics, queue, smart shuffle | **Connect**: one device plays, the others control it; move playback from iPhone to Mac |
| Downloads for offline listening | Modules the server owner can turn on (see below) |
| AirPlay, lock screen, Dynamic Island, Mac app with menu bar controls | |

## The app

- **App Store**: coming soon.
- **Build it yourself**: [`ios/README.md`](ios/README.md) (Xcode 26, XcodeGen).

When signing in, type your Jellyfin address (e.g. `https://jellyfin.example.com` or
`http://192.168.1.10:8096`). If a Sonalex server answers at the same address under `/sonalex`, the
app uses it on its own. Otherwise it works as a regular Jellyfin client.

## The Sonalex server (optional)

A small Python server (FastAPI) that runs **on the same machine as Jellyfin**: it reads your
library's files to prepare the Mix transitions.

### Install (Debian, Ubuntu, Raspberry Pi OS)

```bash
git clone https://github.com/AlexLeDevDu22/sonalex.git
cd sonalex
bash deploy/setup.sh          # creates backend/.env and stops: fill it in
nano backend/.env             # Jellyfin address + an administrator account
bash deploy/setup.sh          # installs everything, starts the services, checks
```

The script is idempotent: it only does what's missing. It can also run a single step
(`packages`, `data`, `python`, `proxy`, `services`, `check`). Details, ports, and setup behind your
own reverse proxy (nginx, Caddy, Traefik): [`deploy/README.md`](deploy/README.md).

How the server works (Mix, Connect, modules, API): [`backend/README.md`](backend/README.md).

### Modules

In `backend/.env`. All off by default:

| Setting | What it adds |
|---|---|
| `SONALEX_ONLINE=1` | **Online catalog**: search, play and add to your library songs it doesn't have. The audio comes from YouTube: check that this is allowed where you live before turning it on. |
| `SONALEX_SPOTIFY_SYNC=1` | **Spotify sync**: likes and playlists follow a Spotify account, every night and live. Experimental. |

**No keys ship with the project**: everyone puts their own in `backend/.env` (Spotify, Last.fm).
How to get them, and what I use myself: [`backend/README.md`](backend/README.md#modules).

## Layout

| Folder | Contents |
|---|---|
| `ios/` | The app (SwiftUI, iOS 18+, Mac Catalyst) |
| `backend/` | The Sonalex server and the Spotify sync |
| `deploy/` | Install: `setup.sh`, systemd service and Caddy templates |
| `docs/` | Mac integrations (`now-playing-mac.md`), App Store listing (`app-store/`) |

## Privacy

The app collects nothing: see [`PRIVACY.md`](PRIVACY.md).

## Contributing

Issues and pull requests are welcome. Sonalex is not affiliated with the Jellyfin project, nor with
Spotify, YouTube or Apple.

## License

[MIT](LICENSE): you can use, modify and redistribute the code, including in a published app, as
long as you keep the copyright notice.
