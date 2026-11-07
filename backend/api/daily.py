"""
daily.py – "Artiste du jour" and "À découvrir" for the home screen.

- Artist of the day: any artist with at least one downloaded song (main or featured). The same all
  day, and not picked again for a year (or, if there are fewer artists than days, the one not seen
  for the longest time). Shown with its public (online) page, so it plays songs not downloaded too.
- To discover: an artist close to the artist of the day (same scene / style, from Last.fm and
  Deezer "similar artists": Spotify removed its own) with none of its songs in the library, and
  not suggested in the last year.

Picks are stored in <data dir>/daily_artists.json, so restarts don't change them.
"""

import json
import random
import threading
from datetime import date, timedelta
from pathlib import Path

import requests

from . import catalog
from .common import DATA_DIR, LASTFM_API_KEY, normalize

STATE = DATA_DIR / "daily_artists.json"
_lock = threading.Lock()


def _load() -> dict:
    try:
        return json.loads(STATE.read_text(encoding="utf8"))
    except (FileNotFoundError, ValueError):
        return {"days": {}}


def _save(state: dict):
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf8")
    tmp.replace(STATE)


def _library_artists() -> dict[str, str]:
    """normalized name → display name, for every artist of a downloaded song."""
    import local_song

    out = {}
    for s in local_song.all_songs():
        if not s.local_path or not Path(s.local_path).exists():
            continue
        for name in [s.artist] + (s.featured_artists or []):
            if name and normalize(name):
                out.setdefault(normalize(name), name)
    return out


def _recent(state: dict, key: str, today: date, days: int = 365) -> dict[str, str]:
    """normalized name → last date it was picked (for `key`), within `days`."""
    since = (today - timedelta(days=days)).isoformat()
    seen = {}
    for day, pick in state["days"].items():
        if day >= since and pick.get(key):
            seen[normalize(pick[key]["name"])] = day
    return seen


def _similar_names(name: str) -> list[str]:
    """Artists of the same style, best first: Last.fm and Deezer merged by rank."""
    lists = []
    if LASTFM_API_KEY:
        try:
            r = requests.get("https://ws.audioscrobbler.com/2.0/", timeout=10, params={
                "method": "artist.getSimilar", "artist": name, "api_key": LASTFM_API_KEY,
                "format": "json", "limit": 40, "autocorrect": 1})
            lists.append([a["name"] for a in r.json().get("similarartists", {}).get("artist", [])])
        except Exception:
            pass
    try:
        dz = catalog.dz_artist_id(name)
        if dz:
            lists.append([a["name"] for a in catalog.dz_get(f"/artist/{dz}/related", {"limit": 40}).get("data", [])])
    except Exception:
        pass
    score: dict[str, float] = {}
    display: dict[str, str] = {}
    for names in lists:
        for rank, n in enumerate(names):
            k = normalize(n)
            display.setdefault(k, n)
            score[k] = score.get(k, 0) + 1 / (rank + 3)  # in both lists → first
    return [display[k] for k in sorted(score, key=score.get, reverse=True)]


def _spotify_artist(name: str) -> dict | None:
    try:
        sid = catalog.resolve_artist_id(f"name:{name}")
        return catalog.norm_sp_artist(catalog.sp_get(f"/artists/{sid}")) if sid else None
    except Exception:
        return None


def _pick_artist(state: dict, today: date, library: dict[str, str]) -> dict | None:
    recent = _recent(state, "artist", today)
    fresh = [k for k in library if k not in recent]
    rng = random.Random(today.isoformat())
    if fresh:
        candidates = rng.sample(fresh, len(fresh))
    else:  # fewer artists than days: the one not shown for the longest time
        candidates = sorted(library, key=lambda k: recent.get(k, ""))
    for k in candidates[:15]:
        artist = _spotify_artist(library[k])
        if artist and normalize(artist["name"]) == k:
            return artist
    return None


def _pick_discover(state: dict, today: date, seed: dict, library: dict[str, str]) -> dict | None:
    recent = _recent(state, "discover", today)
    known = set(library) | {normalize(seed["name"])}
    names = [n for n in _similar_names(seed["name"]) if normalize(n) not in known]
    fresh = [n for n in names if normalize(n) not in recent] or names
    # A bit of variety among the closest ones, still deterministic for the day.
    pool = fresh[:6]
    random.Random(today.isoformat() + "discover").shuffle(pool)
    for n in pool + fresh[6:15]:
        artist = _spotify_artist(n)
        if artist and normalize(artist["name"]) not in known:
            return artist
    return None


def today_picks() -> dict:
    today = date.today()
    with _lock:
        state = _load()
        pick = state["days"].get(today.isoformat())
        if pick and pick.get("artist") and pick.get("discover"):
            return {"date": today.isoformat(), **pick}
        library = _library_artists()
        pick = pick or {}
        if not pick.get("artist"):
            pick["artist"] = _pick_artist(state, today, library)
        if pick.get("artist") and not pick.get("discover"):
            pick["discover"] = _pick_discover(state, today, pick["artist"], library)
            pick["because"] = pick["artist"]["name"]
        if pick.get("artist"):
            state["days"][today.isoformat()] = pick
            # Keep two years of history.
            cutoff = (today - timedelta(days=730)).isoformat()
            state["days"] = {d: p for d, p in state["days"].items() if d >= cutoff}
            _save(state)
        return {"date": today.isoformat(), **pick}
