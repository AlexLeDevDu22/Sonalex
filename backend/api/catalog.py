"""
catalog.py – Online catalog: Spotify (search, artists, albums) and Deezer (public, keyless).

Every track leaves this module in one normalized shape, whatever its source:

    {
      "key": "sp:<spotify id>" | "dz:<deezer id>",
      "title": str,
      "artists": [{"id": "sp:<id>" | "name:<name>", "name": str}],
      "album": {"id": "sp:<id>" | None, "name": str, "image": url | None},
      "durationMs": int, "explicit": bool, "trackNumber": int | None, "discNumber": int | None,
      "year": int | None,
      "jellyfin": None   # filled by library.attach_local when the song is in the library
    }
"""

import os
import threading
import time

import requests

from .common import JsonStore, TTLCache, normalize, song_signature

SPOTIFY_API = "https://api.spotify.com/v1"
DEEZER_API = "https://api.deezer.com"
MARKET = "FR"

_spotify_lock = threading.Lock()
_cache = TTLCache(ttl=3600)
_search_cache = TTLCache(ttl=600)
_matches = JsonStore("spotify_matches.json")  # song signature -> spotify track id ("" = none)


# ---------------------------------------------------------------------------
# Spotify plumbing. The catalog only reads public data: with SPOTIFY_CLIENT_ID / _SECRET (an app
# of your own on developer.spotify.com, official "client credentials"); else the account token of
# the Spotify sync (spotify.py, backend/chosic_data.json).
# ---------------------------------------------------------------------------

_app_token = {"token": None, "expires": 0.0}


def _client_credentials(force: bool = False) -> str | None:
    client_id, secret = os.getenv("SPOTIFY_CLIENT_ID"), os.getenv("SPOTIFY_CLIENT_SECRET")
    if not client_id or not secret:
        return None
    if force or time.time() > _app_token["expires"] - 60:
        r = requests.post("https://accounts.spotify.com/api/token", data={"grant_type": "client_credentials"},
                          auth=(client_id, secret), timeout=10)
        r.raise_for_status()
        data = r.json()
        _app_token.update(token=data["access_token"], expires=time.time() + float(data.get("expires_in", 3600)))
    return _app_token["token"]


def _spotify_headers(force_refresh: bool = False) -> dict:
    with _spotify_lock:
        token = _client_credentials(force_refresh)
        if token:
            return {"Authorization": f"Bearer {token}"}
        import spotify  # the Spotify sync's account token

        if force_refresh:
            spotify.chosic_data["last_refreshed"] = 0
        return spotify._auth_headers()


def sp_get(path: str, params: dict | None = None) -> dict:
    key = (path, tuple(sorted((params or {}).items())))
    hit = _cache.get(key)
    if hit is not None:
        return hit
    headers = _spotify_headers()
    for attempt in range(3):
        r = requests.get(f"{SPOTIFY_API}{path}", headers=headers, params=params, timeout=10)
        if r.status_code == 401:
            headers = _spotify_headers(force_refresh=True)
            continue
        if r.status_code == 429:
            time.sleep(min(float(r.headers.get("Retry-After", "1")), 3))
            continue
        r.raise_for_status()
        data = r.json()
        _cache.set(key, data)
        return data
    r.raise_for_status()
    return {}


def _year(date: str | None) -> int | None:
    try:
        return int((date or "")[:4])
    except ValueError:
        return None


def _image(images: list | None) -> str | None:
    if not images:
        return None
    # Spotify lists the biggest first; ~640px is plenty.
    return images[0].get("url")


def norm_sp_album(a: dict) -> dict:
    return {
        "id": f"sp:{a['id']}",
        "name": a.get("name") or "",
        "artist": ", ".join(x.get("name", "") for x in a.get("artists", [])),
        "artistId": f"sp:{a['artists'][0]['id']}" if a.get("artists") else None,
        "image": _image(a.get("images")),
        "year": _year(a.get("release_date")),
        "type": a.get("album_type"),
        "totalTracks": a.get("total_tracks"),
    }


def norm_sp_track(t: dict, album: dict | None = None) -> dict:
    alb = t.get("album") or album or {}
    return {
        "key": f"sp:{t['id']}",
        "title": t.get("name") or "",
        "artists": [{"id": f"sp:{a['id']}" if a.get("id") else f"name:{a.get('name', '')}", "name": a.get("name", "")}
                    for a in t.get("artists", [])],
        "album": {"id": f"sp:{alb['id']}" if alb.get("id") else None, "name": alb.get("name") or "",
                  "image": _image(alb.get("images"))},
        "durationMs": t.get("duration_ms") or 0,
        "explicit": bool(t.get("explicit")),
        "trackNumber": t.get("track_number"),
        "discNumber": t.get("disc_number"),
        "year": _year(alb.get("release_date")),
        "jellyfin": None,
    }


def norm_sp_playlist(p: dict) -> dict:
    return {
        "id": f"sp:{p['id']}",
        "name": p.get("name") or "",
        "owner": (p.get("owner") or {}).get("display_name") or "",
        "image": _image(p.get("images")),
        "totalTracks": ((p.get("tracks") or p.get("items") or {}) or {}).get("total"),
        "description": p.get("description") or "",
    }


def playlist(spotify_id: str, max_tracks: int = 300) -> dict:
    p = sp_get(f"/playlists/{spotify_id}", {"market": MARKET})
    tracks, offset = [], 0
    while offset < max_tracks:
        page = sp_get(f"/playlists/{spotify_id}/items", {"market": MARKET, "limit": 100, "offset": offset})
        items = page.get("items", [])
        for it in items:
            t = it.get("track") or it.get("item")
            if t and t.get("id") and t.get("type", "track") == "track":
                tracks.append(norm_sp_track(t))
        if not page.get("next"):
            break
        offset += 100
    return {"playlist": norm_sp_playlist(p), "tracks": tracks}


def norm_sp_artist(a: dict) -> dict:
    return {"id": f"sp:{a['id']}", "name": a.get("name") or "", "image": _image(a.get("images")),
            "genres": a.get("genres") or []}


# ---------------------------------------------------------------------------
# Spotify catalog
# ---------------------------------------------------------------------------

def search(q: str, limit: int = 20) -> dict:
    key = (normalize(q), limit)
    hit = _search_cache.get(key)
    if hit is not None:
        return hit
    data = sp_get("/search", {"q": q, "type": "track,artist,album,playlist", "limit": limit, "market": MARKET})
    result = {
        "playlists": [norm_sp_playlist(p) for p in data.get("playlists", {}).get("items", []) if p and p.get("id")],
        "tracks": [norm_sp_track(t) for t in data.get("tracks", {}).get("items", []) if t and t.get("id")],
        "artists": [norm_sp_artist(a) for a in data.get("artists", {}).get("items", []) if a and a.get("id")],
        "albums": [norm_sp_album(a) for a in data.get("albums", {}).get("items", []) if a and a.get("id")],
    }
    _search_cache.set(key, result)
    return result


def sp_track(spotify_id: str) -> dict:
    return sp_get(f"/tracks/{spotify_id}", {"market": MARKET})


def album(spotify_id: str) -> dict:
    a = sp_get(f"/albums/{spotify_id}", {"market": MARKET})
    items = list(a.get("tracks", {}).get("items", []))
    nxt = a.get("tracks", {}).get("next")
    offset = len(items)
    while nxt and offset < 300:
        page = sp_get(f"/albums/{spotify_id}/tracks", {"market": MARKET, "limit": 50, "offset": offset})
        items += page.get("items", [])
        nxt = page.get("next")
        offset += 50
    return {
        "album": norm_sp_album(a),
        "tracks": [norm_sp_track(t, album=a) for t in items if t and t.get("id")],
    }


def resolve_artist_id(artist_id: str) -> str | None:
    """'sp:<id>' → id; 'name:<name>' → best Spotify artist for that name."""
    if artist_id.startswith("sp:"):
        return artist_id[3:]
    if artist_id.startswith("name:"):
        name = artist_id[5:]
        found = sp_get("/search", {"q": name, "type": "artist", "limit": 5, "market": MARKET})
        items = found.get("artists", {}).get("items", [])
        for a in items:
            if normalize(a.get("name")) == normalize(name):
                return a["id"]
        return items[0]["id"] if items else None
    return artist_id


def resolve_album_id(album_id: str) -> str | None:
    """'sp:<id>' → id; 'name:<album>|<artist>' → the public (Spotify) version of a library album."""
    if album_id.startswith("sp:"):
        return album_id[3:]
    if not album_id.startswith("name:"):
        return None
    title, _, artist_name = album_id[5:].partition("|")
    found = sp_get("/search", {"q": f"album:{title} artist:{artist_name}" if artist_name else title,
                               "type": "album", "limit": 10, "market": MARKET})
    items = [a for a in found.get("albums", {}).get("items", []) if a and a.get("id")]
    if not items and artist_name:
        items = [a for a in sp_get("/search", {"q": f"{title} {artist_name}", "type": "album", "limit": 10,
                                                "market": MARKET}).get("albums", {}).get("items", []) if a and a.get("id")]

    def score(a):
        same_title = normalize(a.get("name")) == normalize(title)
        same_artist = any(normalize(x.get("name")) == normalize(artist_name) for x in a.get("artists") or [])
        return (same_title and same_artist, same_artist, same_title, a.get("total_tracks") or 0)
    return max(items, key=score)["id"] if items else None


def artist(artist_id: str) -> dict:
    sid = resolve_artist_id(artist_id)
    if not sid:
        raise LookupError("Artiste introuvable")
    a = sp_get(f"/artists/{sid}")
    top = sp_get(f"/artists/{sid}/top-tracks", {"market": MARKET}).get("tracks", [])
    albums = sp_get(f"/artists/{sid}/albums", {"include_groups": "album", "market": MARKET, "limit": 50}).get("items", [])
    singles = sp_get(f"/artists/{sid}/albums", {"include_groups": "single", "market": MARKET, "limit": 50}).get("items", [])

    def dedupe(items):
        seen, out = set(), []
        for x in items:
            k = normalize(x.get("name"))
            if k not in seen:
                seen.add(k)
                out.append(norm_sp_album(x))
        return out

    return {
        "artist": norm_sp_artist(a),
        "top": [norm_sp_track(t) for t in top if t and t.get("id")],
        "albums": dedupe(albums),
        "singles": dedupe(singles),
    }


def artist_tracks(artist_id: str, max_albums: int = 30) -> list[dict]:
    """Every track of the artist: top tracks first, then albums and singles (newest first)."""
    page = artist(artist_id)
    sid = page["artist"]["id"][3:]
    tracks = list(page["top"])
    seen = {song_signature(t["title"], t["artists"][0]["name"] if t["artists"] else "") for t in tracks}
    from concurrent.futures import ThreadPoolExecutor

    wanted = (page["albums"] + page["singles"])[:max_albums]
    with ThreadPoolExecutor(max_workers=6) as pool:
        pages = list(pool.map(lambda a: album(a["id"][3:]), wanted))
    for alb_page in pages:
        for t in alb_page["tracks"]:
            # Keep only tracks the artist actually plays on.
            if not any(a["id"] == f"sp:{sid}" for a in t["artists"]):
                continue
            sig = song_signature(t["title"], t["artists"][0]["name"])
            if sig in seen:
                continue
            seen.add(sig)
            tracks.append(t)
    return tracks


def find_spotify_track(title: str, artist_name: str) -> dict | None:
    """Best Spotify track for a title/artist (cached on disk)."""
    sig = song_signature(title, artist_name)
    known = _matches.get(sig)
    if known == "":
        return None
    if known:
        try:
            return norm_sp_track(sp_track(known))
        except Exception:
            pass
    for q in (f'track:"{title}" artist:"{artist_name}"', f"{title} {artist_name}"):
        items = sp_get("/search", {"q": q, "type": "track", "limit": 5, "market": MARKET}).get("tracks", {}).get("items", [])
        for t in items:
            if not t or not t.get("id"):
                continue
            names = " ".join(normalize(a.get("name")) for a in t.get("artists", []))
            if base_ok(t.get("name"), title) and normalize(artist_name).split(" feat")[0] in names:
                _matches.set(sig, t["id"])
                return norm_sp_track(t)
    _matches.set(sig, "")
    return None


def base_ok(candidate: str | None, wanted: str | None) -> bool:
    from .common import base_title

    a, b = base_title(candidate), base_title(wanted)
    return bool(a and b) and (a == b or a in b or b in a)


# ---------------------------------------------------------------------------
# Deezer (public API, used for recommendations: no key, generous limits)
# ---------------------------------------------------------------------------

def dz_get(path: str, params: dict | None = None) -> dict:
    key = ("dz", path, tuple(sorted((params or {}).items())))
    hit = _cache.get(key)
    if hit is not None:
        return hit
    r = requests.get(f"{DEEZER_API}{path}", params=params, timeout=10)
    r.raise_for_status()
    data = r.json()
    if isinstance(data, dict) and data.get("error"):
        raise LookupError(str(data["error"]))
    _cache.set(key, data)
    return data


def norm_dz_track(t: dict) -> dict:
    alb = t.get("album") or {}
    contributors = t.get("contributors") or [t.get("artist") or {}]
    return {
        "key": f"dz:{t['id']}",
        "title": t.get("title") or "",
        "artists": [{"id": f"name:{c.get('name', '')}", "name": c.get("name", "")} for c in contributors if c.get("name")],
        "album": {"id": None, "name": alb.get("title") or "", "image": alb.get("cover_xl") or alb.get("cover_big")},
        "durationMs": int(t.get("duration") or 0) * 1000,
        "explicit": bool(t.get("explicit_lyrics")),
        "trackNumber": t.get("track_position"),
        "discNumber": t.get("disk_number"),
        "year": None,
        "jellyfin": None,
    }


def dz_track(deezer_id: str) -> dict:
    return dz_get(f"/track/{deezer_id}")


def dz_artist_id(name: str) -> int | None:
    found = dz_get("/search/artist", {"q": name, "limit": 5}).get("data", [])
    for a in found:
        if normalize(a.get("name")) == normalize(name):
            return a["id"]
    return found[0]["id"] if found else None


def dz_search_track(title: str, artist_name: str) -> dict | None:
    found = dz_get("/search", {"q": f'artist:"{artist_name}" track:"{title}"', "limit": 5}).get("data", [])
    if not found:
        found = dz_get("/search", {"q": f"{artist_name} {title}", "limit": 5}).get("data", [])
    for t in found:
        if base_ok(t.get("title"), title) and normalize(artist_name).split(" feat")[0] in normalize(
                (t.get("artist") or {}).get("name")):
            return t
    return None


def find_lyrics_of(key: str) -> tuple[str | None, bool]:
    """(lyrics, synced) of an online song, from LRCLIB."""
    from utils.lyrics import find_lyrics

    meta = track_meta(key)
    artist = meta["artists"][0]["name"] if meta.get("artists") else ""
    return find_lyrics(meta["title"], artist, (meta.get("album") or {}).get("name"),
                       (meta.get("durationMs") or 0) / 1000 or None)


def track_meta(key: str) -> dict:
    """Normalized metadata for any track key (used to find the audio and to save it)."""
    if key.startswith("sp:"):
        return norm_sp_track(sp_track(key[3:]))
    if key.startswith("dz:"):
        return norm_dz_track(dz_track(key[3:]))
    raise LookupError(f"Clé inconnue : {key}")
