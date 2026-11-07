# The Sonalex server

What the app adds on top of Jellyfin, served at the Jellyfin address under `/sonalex/` (see
[`deploy/README.md`](../deploy/README.md) for the install and the relay).

```
backend/
  config.py            settings (read from .env, overridden by config.ini)
  api/                 the server (FastAPI, uvicorn): python -m uvicorn api.server:app
    server.py          routes, authentication (the app's Jellyfin token)
    automix.py         Mix: planning and rendering the transitions (ffmpeg)
    mixinfo.py         Mix: song analysis (tempo, beats, key, voice)
    connect.py         Connect: devices, the playing device, commands
    streamer.py …      optional modules: online catalog (streamer, catalog, saver, radio,
                       daily, credits, library) and live Spotify sync (live_worker)
  full_refreshing.py   nightly Spotify sync (Spotify module)
  sync.py, liked.py, playlists.py, spotify.py, downloading.py …   Spotify module
  utils/               one-off maintenance scripts (run by hand)
```

## Settings

Everything is in `backend/.env` (template: [`.env.example`](.env.example)):

| Variable | Role |
|---|---|
| `SONALEX_JELLYFIN_URL` | Jellyfin as this machine reaches it (`http://127.0.0.1:8096`, or `:8097` behind the Caddy relay) |
| `JELLYFIN_USER`, `JELLYFIN_PW` | a Jellyfin administrator account: the server uses it to know where the files are |
| `JELLYFIN_USER_ID` | optional (found when signing in) |
| `JELLYFIN_API_KEY` | several users (see below) |
| `SONALEX_SIGNUPS` | `0` = no account requests from the app |
| `SONALEX_DATA_DIR` | data: `Musics/` (the Spotify module's library), `logs/`, `temp/`, caches (`mixinfo.json`…) |
| `SONALEX_ONLINE` | `1` = online catalog |
| `SONALEX_SPOTIFY_SYNC` | `1` = Spotify sync |
| `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET` | the online catalog's Spotify search (your own keys, see below) |
| `LASTFM_API_KEY` | recommendations (autoplay, stations), with the online catalog |
| `SONALEX_PROXY`, `SONALEX_*_PORT` | read by `deploy/setup.sh` only |

The app reads `GET /api/health` (`{"features": {"online": …, "spotifySync": …}}`) and only shows
what the server offers. The routes of a module that's off answer 404.

## Always on

### Mix: DJ transitions

The app plays, without any gap, *pieces* the server prepares: each song, with the transition from
the previous one at its start (`automix.py`). For each transition A → B:

1. **Analysis** (`mixinfo.py`, ~3 s per song, cached): tempo, beat and bar grids at the start and
   the end, key (Camelot wheel), loudness, and **where the voice is**. The voice comes from the
   **synced lyrics** (`.lrc` next to the file); without them, from a cautious estimate. Tip:
   Jellyfin's *LrcLib* plugin, with lyrics saved into the media folders, gives `.lrc` files to
   almost a whole library.
2. **Two rules**, whatever the style: B never starts before A's lyrics are over, and A is gone when
   B starts singing.
3. **Style**:
   - *glide* (tempos within 8 %, or half / double time): A's tempo slides to B's (rubberband, pitch
     kept, never audible on a voice), one of A's downbeats lands on B's first downbeat, the highs
     cross, the basslines swap on a downbeat. The server then checks **on the rendered audio**
     that both rhythms fall together (and moves B if a grid was half a beat off). Clashing keys get
     a shorter blend;
   - *echo* (tempos too far apart): a filter takes A's bass away once its voice is over, A stops on
     a downbeat and its last two beats ring out in echoes while B comes in;
   - *join* (no usable rhythm): A to its last sound, B right after, without the files' silences.

`GET /api/mix/segment?key=&prev=&next=&start=&until=` plans and starts the render,
`GET /api/mix/stream/{id}` serves the file (Apple Lossless). One render at a time.

### Connect

Each app keeps a WebSocket open (`/api/connect`). For each Jellyfin account, the server knows which
devices are there and which one plays: the playing device sends its state to the others, the
others send it commands, and `transfer` moves playback from one device to another.

## Several users

Friends can have an account on your server, each with **their own library**: they only see their
songs, playlists and favorites, and sync their own Spotify or Deezer account. A song several people
have is **one file**: each library holds a hard link to it, so it takes the room of one copy, and
saving a song a friend already has is instant (nothing is downloaded).

**Turn it on**: in Jellyfin, *Dashboard → API Keys → +* (name it "Sonalex server"), put the key in
`backend/.env` as `JELLYFIN_API_KEY=…`, then `systemctl --user restart sonalex-server`. (A user
session only sees its own libraries: the server needs the key to manage everyone's.)

**Joining**: in the app, *Create an Account* → the server's address → first name, password, music
service. The server creates the Jellyfin user right away but **disabled**, and tells the owner (a
notification in their app, the admin page). Accepting creates the user's folder
(`<data>/users/<name>/Musics`) and Jellyfin library, keeps the libraries apart, and enables the
user: their app signs in by itself. Refusing deletes the Jellyfin user. The first user (the
server's own account) keeps their files where they were.

**Music services**, per user (`SONALEX_SPOTIFY_SYNC=1`):

- **Spotify**: the user signs in to Spotify in the app (*Profile → Music Service → Connect
  Spotify*). It goes through **your** Spotify app (`SPOTIFY_CLIENT_ID`): add
  `sonalex://spotify-callback` to its redirect URIs, and since Spotify keeps new apps in
  development mode, add each friend's Spotify e-mail in its *User Management*. Their likes and
  playlists then sync both ways, like yours.
- **Deezer**: the user gives the link of their **public** Deezer profile. Their favorites and
  playlists come into their library every night (Deezer → server only: Deezer doesn't give
  access tokens anymore, so nothing can be written back).

**Social**: the apps report what they play (`<data>/plays.db`). Everyone sees the other users'
profiles (listening time, when, top songs and artists, song of the moment, what they're playing
now) and, under a song, who else has it and who likes it. A user can hide themselves
(*Music Service → Show Me to Friends*).

**Admin page**: `https://<your Jellyfin address>/sonalex/admin` (sign in with a Jellyfin
administrator): requests to accept, users (songs, room taken of their own and shared, listening
time, last song, what they play now, their stats), latest songs of everyone, the server (disk, room
the music takes and what sharing saves, memory, temperature, modules).

How it runs: `accounts.py` (accounts, requests, libraries), `library_index.py` (who has which song),
`user_jobs.py` (a job for one user: the sync modules work for one user at a time, in a process with
`SONALEX_USER=<slug>`), `deezer_sync.py`, `spotify_auth.py`, `api/community.py` + `api/social.py`
(routes, plays), `api/admin.html`.

## Modules

### Online catalog (`SONALEX_ONLINE=1`)

Search (Spotify, Deezer), artist and album pages, playback of songs that aren't in the library (the
audio is found on YouTube Music and downloaded while it plays), adding to the library (the song is
filed and tagged like the others), recommendations (Last.fm, Deezer), artist of the day, credits
(Genius). **Check that downloading from YouTube is allowed where you live before turning it on**:
it's your responsibility.

**Keys** (none ship with the project, everyone uses their own):

- **Spotify** (search, artists, albums): create a free app on
  [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and put its *Client
  ID* and *Client secret* in `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` (official access to
  public data). Spotify limits what new apps can read: some editorial playlists may be missing.
- **Last.fm** (recommendations): a free key at [last.fm/api](https://www.last.fm/api/account/create).
- Deezer, YouTube Music and LRCLIB (lyrics) don't need one.

> **What I use myself:** no Spotify developer keys, but the account token given by
> [chosic.com](https://www.chosic.com/spotify-playlist-analyzer/) (its *Playlist Analyzer*, once
> connected to Spotify), in `backend/chosic_data.json` (template:
> [`chosic_data.json.example`](chosic_data.json.example)). The catalog uses it when the keys above
> are empty. It isn't an official API: it can stop working any day, and it's up to you whether you
> want to use it.

### Spotify sync (`SONALEX_SPOTIFY_SYNC=1`) — experimental

Jellyfin is the master: favorites and playlists changed in Jellyfin (or the app) are pushed to
Spotify live; every night, `full_refreshing.py` does the opposite (new Spotify likes and playlists
downloaded), plus maintenance (missing files, duplicates, lyrics). It needs a token **of your
Spotify account** (to read your likes and edit your playlists: developer keys alone can't): the
chosic.com one, as described above, in `backend/chosic_data.json`, with `SPOTIFY_USER_ID` (your
Spotify user id). With `ONLY_LIKED = True` (`config.ini`), songs that are no longer liked nor in a
followed playlist **are deleted** the following night.

```bash
cd backend && .venv/bin/python spotify_refreshing.py --dry-run   # first catch-up, dry run
```

## Developing

```bash
cd backend && .venv/bin/python -m uvicorn api.server:app --port 18098 --reload
```

The app's logs (player events) end up in `<data>/logs/player-debug.log`.
