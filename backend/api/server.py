"""
server.py – Sonalex server (FastAPI): what the app adds on top of Jellyfin.

Served on 127.0.0.1:8098 and exposed by a reverse proxy on the Jellyfin address: /sonalex/* → this
app, everything else → Jellyfin (see deploy/). Every route except /api/health needs the user's
Jellyfin token (Authorization: MediaBrowser … Token="…", X-Emby-Token, or ?ApiKey= for audio URLs).

Always on: Mix (DJ transitions between the songs of the library) and Connect (one device plays,
the others control it). Optional modules (config.py): the online catalog, the Spotify sync.

Run:  .venv/bin/python -m uvicorn api.server:app --host 127.0.0.1 --port 8098
"""

import json
import re
import threading
import time
from datetime import datetime
from pathlib import Path

import requests
from fastapi import Depends, FastAPI, HTTPException, Request, Response, WebSocket
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel

from . import automix, catalog, daily, radio as radio_mod, saver
from .connect import HUB
from .common import BACKEND_DIR, JELLYFIN_URL, LOG_DIR, TTLCache, parse_range
from .library import LIBRARY
from .live_worker import LIVE
from .streamer import STREAMER

from config import ONLINE, SPOTIFY_SYNC  # noqa: E402

VERSION = "1.0"
app = FastAPI(title="Sonalex server", version=VERSION)

_tokens = TTLCache(ttl=600)
_lyrics = TTLCache(ttl=24 * 3600)
PLAYER_LOG = LOG_DIR / "player-debug.log"
API_LOG = LOG_DIR / "server.log"
LOG_MAX_BYTES = 20 * 1024 ** 2


def _trim_log(path: Path):
    """Keeps only the end of a log that got too big (systemd keeps the API's open in append mode:
    it must be rewritten in place, not replaced)."""
    try:
        if not path.exists() or path.stat().st_size <= LOG_MAX_BYTES:
            return
        with path.open("r+b") as f:
            f.seek(-LOG_MAX_BYTES // 2, 2)
            tail = f.read()
            f.seek(0)
            f.truncate()
            f.write(tail[tail.find(b"\n") + 1:])
    except OSError as e:
        print(f"[api] log {path.name}: {e!r}")


# ---------------------------------------------------------------------------
# Auth: the app's Jellyfin session is the key
# ---------------------------------------------------------------------------

# Jellyfin 12 no longer accepts the legacy X-Emby-Token header: always talk to it with
# "Authorization: MediaBrowser … Token=…" (still accepted from the apps on the way in).
class Auth:
    def __init__(self, token: str, user_id: str):
        self.token = token
        self.user_id = user_id

    @property
    def headers(self) -> dict:
        return {"Authorization": f'MediaBrowser Client="Musique API", Device="Pi", DeviceId="musique-api", '
                                 f'Version="1.0", Token="{self.token}"'}


def _token_from(request: Request) -> str | None:
    header = request.headers.get("authorization", "")
    m = re.search(r'Token="([^"]+)"', header)
    if m:
        return m.group(1)
    if header.lower().startswith("bearer "):
        return header[7:].strip()
    return (request.headers.get("x-emby-token") or request.query_params.get("ApiKey")
            or request.query_params.get("api_key"))


def _user_for_token(token: str) -> str | None:
    """The Jellyfin user of a token; None if it isn't valid. Raises RequestException if Jellyfin
    can't be reached."""
    user_id = _tokens.get(token)
    if user_id:
        return user_id
    r = requests.get(f"{JELLYFIN_URL}/Users/Me", headers=Auth(token, "").headers, timeout=8)
    if r.status_code != 200:
        return None
    user_id = r.json()["Id"]
    _tokens.set(token, user_id)
    return user_id


def auth(request: Request) -> Auth:
    token = _token_from(request)
    if not token:
        raise HTTPException(401, "Not signed in")
    try:
        user_id = _user_for_token(token)
    except requests.RequestException:
        raise HTTPException(503, "Jellyfin unreachable")
    if not user_id:
        raise HTTPException(401, "Invalid Jellyfin session")
    return Auth(token, user_id)


def online(a: Auth = Depends(auth)) -> Auth:
    """Routes of the online catalog: only when the server owner turned it on."""
    if not ONLINE:
        raise HTTPException(404, "The online catalog is off on this server")
    return a


def spotify_sync(a: Auth = Depends(auth)) -> Auth:
    if not SPOTIFY_SYNC:
        raise HTTPException(404, "The Spotify sync is off on this server")
    return a


def _attach(tracks: list[dict], a: Auth) -> list[dict]:
    return LIBRARY.attach_local(tracks, a.headers, a.user_id)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/api/health")
def health():
    # The app shows only what this server offers.
    return {"ok": True, "name": "Sonalex server", "version": VERSION,
            "features": {"mix": True, "connect": True, "online": ONLINE, "spotifySync": SPOTIFY_SYNC}}


@app.get("/api/search")
async def search(q: str, limit: int = 20, a: Auth = Depends(online)):
    q = q.strip()
    if not q:
        return {"tracks": [], "artists": [], "albums": []}
    result = await run_in_threadpool(catalog.search, q, min(max(limit, 1), 50))
    tracks = [dict(t) for t in result["tracks"]]
    await run_in_threadpool(_attach, tracks, a)
    return {"tracks": tracks, "artists": result["artists"], "albums": result["albums"],
            "playlists": result.get("playlists", [])}


@app.get("/api/artist/{artist_id}")
async def artist(artist_id: str, a: Auth = Depends(online)):
    try:
        page = await run_in_threadpool(catalog.artist, artist_id)
    except LookupError as e:
        raise HTTPException(404, str(e))
    page["top"] = [dict(t) for t in page["top"]]
    await run_in_threadpool(_attach, page["top"], a)
    return page


@app.get("/api/artist/{artist_id}/tracks")
async def artist_tracks(artist_id: str, a: Auth = Depends(online)):
    tracks = [dict(t) for t in await run_in_threadpool(catalog.artist_tracks, artist_id)]
    await run_in_threadpool(_attach, tracks, a)
    return {"tracks": tracks}


@app.get("/api/album/{album_id}")
async def album(album_id: str, a: Auth = Depends(online)):
    # "sp:<id>", or "name:<album>|<artist>" for the public version of a library album.
    sid = await run_in_threadpool(catalog.resolve_album_id, album_id)
    if not sid:
        raise HTTPException(404, "Album not found online")
    page = await run_in_threadpool(catalog.album, sid)
    page["tracks"] = [dict(t) for t in page["tracks"]]
    await run_in_threadpool(_attach, page["tracks"], a)
    return page


@app.get("/api/playlist/{playlist_id}")
async def playlist(playlist_id: str, a: Auth = Depends(online)):
    if not playlist_id.startswith("sp:"):
        raise HTTPException(404, "Unknown playlist")
    try:
        page = await run_in_threadpool(catalog.playlist, playlist_id[3:])
    except requests.HTTPError as e:
        raise HTTPException(404, "This playlist isn’t accessible.") from e
    page["tracks"] = [dict(t) for t in page["tracks"]]
    await run_in_threadpool(_attach, page["tracks"], a)
    return page


class PrepareBody(BaseModel):
    keys: list[str]


@app.post("/api/prepare")
def prepare(body: PrepareBody, a: Auth = Depends(online)):
    """Starts finding + downloading songs ahead of time (the next ones in the queue)."""
    for key in body.keys[:5]:
        STREAMER.job(key)
    return {"ok": True}


@app.get("/api/status/{key}")
def status(key: str, a: Auth = Depends(online)):
    return STREAMER.status(key)


@app.get("/api/stream/{key}")
async def stream(key: str, request: Request, a: Auth = Depends(online)):
    return await STREAMER.serve(key, request.headers.get("range"))


@app.head("/api/stream/{key}")
async def stream_head(key: str, request: Request, a: Auth = Depends(online)):
    return await STREAMER.serve(key, request.headers.get("range"), head=True)


class SaveBody(BaseModel):
    favorite: bool = False
    playlistId: str | None = None


@app.post("/api/save/{key}")
async def save(key: str, body: SaveBody, a: Auth = Depends(online)):
    try:
        item = await run_in_threadpool(saver.save, key, body.favorite, body.playlistId, a.headers, a.user_id)
        if body.playlistId:
            LIVE.submit("playlist", body.playlistId)
    except LookupError as e:
        raise HTTPException(404, str(e))
    except Exception as e:
        print("[save] failed:", repr(e))
        raise HTTPException(500, str(e) or "Couldn’t save the song")
    return {"jellyfin": item}


class RadioBody(BaseModel):
    seed: dict
    recent: list[dict] = []
    limit: int = 25


@app.post("/api/radio")
async def radio(body: RadioBody, a: Auth = Depends(online)):
    tracks = await run_in_threadpool(radio_mod.radio, body.seed, body.recent[-200:], min(body.limit, 50),
                                     a.headers, a.user_id)
    return {"tracks": tracks}


@app.get("/api/lyrics/{key}")
async def lyrics(key: str, a: Auth = Depends(online)):
    """Synced lyrics from LRCLIB, in Jellyfin's format (Start in ticks)."""
    hit = _lyrics.get(key)
    if hit is not None:
        return hit

    def fetch():
        text, synced = catalog.find_lyrics_of(key)
        if not text:
            return {"Lyrics": []}
        lines = []
        if synced:
            for raw in text.splitlines():
                m = re.match(r"\[(\d+):(\d+(?:\.\d+)?)\]\s?(.*)", raw)
                if m:
                    seconds = int(m.group(1)) * 60 + float(m.group(2))
                    lines.append({"Text": m.group(3), "Start": int(seconds * 10_000_000)})
        if not lines:
            lines = [{"Text": t} for t in text.splitlines()]
        return {"Lyrics": lines}

    result = await run_in_threadpool(fetch)
    _lyrics.set(key, result)
    return result


@app.websocket("/api/connect")
async def connect(ws: WebSocket):
    """Musique Connect: see connect.py. ?ApiKey=<jellyfin token>&deviceId=&name=&kind="""
    q = ws.query_params
    token = q.get("ApiKey") or q.get("api_key") or ""
    try:
        user_id = await run_in_threadpool(_user_for_token, token) if token else None
    except requests.RequestException:
        user_id = None
    if not user_id or not q.get("deviceId"):
        await ws.close(code=4401)
        return
    await ws.accept()
    try:
        volume = min(max(float(q.get("volume", "")), 0.0), 1.0)
    except ValueError:
        volume = None
    await HUB.serve(ws, user_id, q["deviceId"], q.get("name") or "Appareil", q.get("kind") or "phone", volume)


# ---------------------------------------------------------------------------
# Live Spotify sync: the app pings after editing a playlist (returns at once)
# ---------------------------------------------------------------------------

@app.post("/api/sync/playlist/{playlist_id}", status_code=202)
def sync_playlist(playlist_id: str, a: Auth = Depends(spotify_sync)):
    LIVE.submit("playlist", playlist_id)
    return {"queued": True}


@app.get("/api/mix/segment")
async def mix_segment(key: str, prev: str | None = None, next: str | None = None, start: float = 0.0,
                      until: float | None = None, a: Auth = Depends(auth)):
    """Mix mode: the segment of `key` (transition in from `prev`, then the song until its cut
    towards `next`), rendered in the background; the app plays segments back to back."""
    return await run_in_threadpool(automix.segment, key, prev, next, start, until)


async def _file_response(path, range_header: str | None, head: bool, media_type: str):
    size = path.stat().st_size
    byte_range = parse_range(range_header, size)
    if byte_range is None:
        return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
    start, end = byte_range
    headers = {"Accept-Ranges": "bytes", "Content-Length": str(end - start + 1), "Cache-Control": "no-store"}
    status = 206 if range_header else 200
    if range_header:
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"
    if head:
        return Response(status_code=status, headers=headers, media_type=media_type)

    def read():
        with open(path, "rb") as f:
            f.seek(start)
            return f.read(end - start + 1)

    # Off the event loop: a whole segment (tens of MB) would freeze the WebSockets meanwhile.
    return Response(content=await run_in_threadpool(read), status_code=status, headers=headers, media_type=media_type)


@app.api_route("/api/mix/stream/{mix_id}", methods=["GET", "HEAD"])
async def mix_stream(mix_id: str, request: Request, a: Auth = Depends(auth)):
    if not re.fullmatch(r"[0-9a-f]{20}", mix_id):
        raise HTTPException(404, "Unknown mix")
    path = await run_in_threadpool(automix.wait_file, mix_id)
    if not path:
        raise HTTPException(404, "Transition unavailable")
    response = await _file_response(path, request.headers.get("range"), request.method == "HEAD", "audio/mp4")
    # The song's real start in the segment, measured at render time (beat alignment).
    for k, v in automix.segment_meta(mix_id).items():
        response.headers[f"X-Segment-{k}"] = str(v)
    return response


@app.get("/api/resolve/album")
async def resolve_album(title: str, artist: str = "", a: Auth = Depends(online)):
    """The online (Spotify) version of a library album: {"id": "sp:…"} or {"id": null}."""
    from .common import base_title, normalize

    def find():
        q = f'album:"{title}"' + (f' artist:"{artist}"' if artist else "")
        items = catalog.sp_get("/search", {"q": q, "type": "album", "limit": 10, "market": catalog.MARKET}) \
            .get("albums", {}).get("items", [])
        want_t, want_a = base_title(title), normalize(artist)
        for x in items:
            if not x or base_title(x.get("name")) != want_t:
                continue
            names = " ".join(normalize(ar.get("name")) for ar in x.get("artists") or [])
            if not want_a or want_a in names or any(normalize(ar.get("name")) in want_a for ar in x.get("artists") or []):
                return {"id": f"sp:{x['id']}", "name": x.get("name")}
        return {"id": None}

    return await run_in_threadpool(find)


@app.get("/api/credits")
async def song_credits(title: str, artist: str, a: Auth = Depends(online)):
    """Who made the song (performers, producers, writers, engineers, label), from Genius."""
    from . import credits

    try:
        return await run_in_threadpool(credits.credits, title, artist)
    except requests.RequestException:
        raise HTTPException(502, "Credits unavailable right now")


@app.get("/api/daily")
async def daily_picks(a: Auth = Depends(online)):
    """Home screen: artist of the day (from your library, public page) + one to discover."""
    return await run_in_threadpool(daily.today_picks)


@app.post("/api/debug/player", status_code=204)
async def debug_player(request: Request, a: Auth = Depends(auth)):
    """Player events from the apps (PlayerDiagnostics.swift), one JSON line each."""
    body = await request.json()
    PLAYER_LOG.parent.mkdir(parents=True, exist_ok=True)
    with PLAYER_LOG.open("a", encoding="utf8") as f:
        for e in (body.get("events") or [])[:200]:
            when = datetime.fromtimestamp(float(e.get("at") or 0)).strftime("%m-%d %H:%M:%S")
            f.write(f"{when} {json.dumps(e, ensure_ascii=False)}\n")


@app.post("/api/sync", status_code=202)
def sync_all(a: Auth = Depends(spotify_sync)):
    LIVE.submit("reconcile", delay=0)
    return {"queued": True}


@app.get("/api/sync/status")
def sync_status(a: Auth = Depends(spotify_sync)):
    return {"lastReconcile": LIVE.last_reconcile, "lastError": LIVE.last_error,
            "jellyfinSocket": LIVE.websocket_connected, "favoriteEvents": LIVE.favorite_events}


@app.on_event("startup")
def warm_up():
    for log in (PLAYER_LOG, API_LOG):
        _trim_log(log)
    print(f"[api] Sonalex server {VERSION} – online catalog: {'on' if ONLINE else 'off'}, "
          f"Spotify sync: {'on' if SPOTIFY_SYNC else 'off'}", flush=True)
    if SPOTIFY_SYNC:
        LIVE.start()
    if ONLINE:
        threading.Thread(target=STREAMER.warm_up, daemon=True).start()
        started = time.time()
        LIBRARY.refresh(force_index=True)
        print(f"[api] library index ready in {time.time() - started:.1f}s")
