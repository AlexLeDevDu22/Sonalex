"""
radio.py – Endless, personal "what comes next" after a song (free sources only).

Candidates come from:
  - Last.fm track.getSimilar (what people listen to after this exact song);
  - Deezer's artist radio (the artist and close artists, refreshed on every call);
  - your own library: downloaded songs by the seed artist and Deezer-related artists
    (they play instantly and are, by definition, to your taste).
They are de-duplicated, stripped of what you just heard, and interleaved so the same
artist never plays more than twice in a row.
"""

import random
import re
from concurrent.futures import ThreadPoolExecutor

import requests

from . import catalog
from .common import LASTFM_API_KEY, TTLCache, normalize, song_signature
from .library import LIBRARY

_lastfm_cache = TTLCache(ttl=6 * 3600)
_pool = ThreadPoolExecutor(max_workers=8)


def _lastfm_similar(title: str, artist: str, limit: int = 50) -> list[tuple[str, str, float]]:
    if not LASTFM_API_KEY or not title or not artist:
        return []
    key = (normalize(title), normalize(artist))
    hit = _lastfm_cache.get(key)
    if hit is not None:
        return hit
    try:
        r = requests.get("https://ws.audioscrobbler.com/2.0/", timeout=8, params={
            "method": "track.getSimilar", "artist": artist, "track": title, "api_key": LASTFM_API_KEY,
            "format": "json", "limit": limit, "autocorrect": 1,
        })
        items = r.json().get("similartracks", {}).get("track", []) if r.ok else []
    except Exception:
        items = []
    result = [(i["name"], i["artist"]["name"], float(i.get("match", 0))) for i in items]
    _lastfm_cache.set(key, result)
    return result


def _deezer_radio(artist: str) -> tuple[list[dict], list[str]]:
    """(radio tracks, related artist names) for an artist name."""
    try:
        aid = catalog.dz_artist_id(artist)
    except Exception:
        return [], []
    if not aid:
        return [], []
    tracks, related = [], []
    try:
        # Not cached on purpose: Deezer returns a different radio each time.
        data = requests.get(f"{catalog.DEEZER_API}/artist/{aid}/radio", params={"limit": 40}, timeout=8).json()
        tracks = [catalog.norm_dz_track(t) for t in data.get("data", [])]
    except Exception:
        pass
    try:
        related = [a["name"] for a in catalog.dz_get(f"/artist/{aid}/related", {"limit": 15}).get("data", [])]
    except Exception:
        pass
    return tracks, related


def _local_track(sid: str) -> dict:
    t = LIBRARY.by_sid.get(sid, {})
    names = [t.get("artist")] + list(t.get("featured_artists") or [])
    return {
        "key": f"sp:{sid}", "title": t.get("title") or "",
        "artists": [{"id": f"name:{n}", "name": n} for n in names if n],
        "album": {"id": None, "name": t.get("album_name") or "", "image": t.get("cover_url")},
        "durationMs": 0, "explicit": False, "trackNumber": None, "discNumber": None, "year": None,
        "jellyfin": None,
    }


def _primary(t: dict) -> str:
    return normalize(t["artists"][0]["name"]) if t.get("artists") else ""


def radio(seed: dict, recent: list[dict], limit: int, user_headers: dict, user_id: str) -> list[dict]:
    title = seed.get("title") or ""
    artist = re.split(r",| feat\.? | & ", seed.get("artist") or "")[0].strip()
    seen = {song_signature(title, artist)}
    seen |= {song_signature(r.get("title"), r.get("artist")) for r in recent}

    lastfm_future = _pool.submit(_lastfm_similar, title, artist)
    dz_tracks, related = _deezer_radio(artist) if artist else ([], [])
    lastfm = lastfm_future.result()

    # Last.fm only gives names: find them on Deezer (cover, duration, playable key) in parallel.
    def resolve(entry):
        t_title, t_artist, _ = entry
        try:
            found = catalog.dz_search_track(t_title, t_artist)
            return catalog.norm_dz_track(found) if found else None
        except Exception:
            return None

    lastfm_tracks = [t for t in _pool.map(resolve, lastfm[:25]) if t]

    local_sids = LIBRARY.local_tracks_for_artists([artist] + related[:10], max(limit // 3, 4), seen)
    local_tracks = [_local_track(sid) for sid in local_sids]

    random.shuffle(dz_tracks)
    sources = [lastfm_tracks, dz_tracks, local_tracks]
    weights = [3, 3, 2]

    result: list[dict] = []
    seed_artist = normalize(artist)
    seed_count = 0
    cursors = [0, 0, 0]
    while len(result) < limit and any(c < len(s) for c, s in zip(cursors, sources)):
        for i, src in enumerate(sources):
            for _ in range(weights[i]):
                if cursors[i] >= len(src) or len(result) >= limit:
                    break
                t = src[cursors[i]]
                cursors[i] += 1
                sig = song_signature(t["title"], t["artists"][0]["name"] if t["artists"] else "")
                if sig in seen:
                    continue
                p = _primary(t)
                # Variety: never 3 in a row from one artist, the seed artist ≤ ~30 %.
                if len(result) >= 2 and _primary(result[-1]) == p and _primary(result[-2]) == p:
                    continue
                if p == seed_artist:
                    if seed_count >= max(2, limit * 3 // 10):
                        continue
                    seed_count += 1
                seen.add(sig)
                result.append(t)

    return LIBRARY.attach_local(result, user_headers, user_id)
