"""
deezer_sync.py – A Deezer account's favorites and playlists, in its user's library (one way).

Deezer's public API reads a public profile without any key: its "Coups de cœur" become the
user's favorites in Jellyfin, its playlists their playlists, the songs are downloaded (or linked,
when someone on the server already has them). Deezer is the master: what's removed there is removed
here. Nothing goes back to Deezer (writing needs an access token Deezer no longer gives out).

Runs for one user: SONALEX_USER=<slug> (see config.py), from full_refreshing.py.
"""

import json
import time
from pathlib import Path

import requests

import jellyfin
import local_song
from config import USER
from downloading import download_song
from song import Song

API = "https://api.deezer.com"
STATE = Path(USER["home"]) / "deezer_state.json" if USER else None


def _get(path: str, params: dict | None = None) -> dict:
    for attempt in range(4):
        try:
            r = requests.get(path if path.startswith("http") else f"{API}{path}", params=params, timeout=20)
            data = r.json()
        except (requests.RequestException, ValueError):
            time.sleep(2 * (attempt + 1))
            continue
        if isinstance(data, dict) and (data.get("error") or {}).get("code") == 4:  # quota: 50 requests / 5 s
            time.sleep(5)
            continue
        return data
    raise RuntimeError(f"Deezer unreachable ({path})")


def _all(path: str) -> list[dict]:
    items, url, params = [], path, {"limit": 100}
    while url:
        data = _get(url, params)
        if data.get("error"):
            raise RuntimeError(f"Deezer: {data['error'].get('message')}")
        items += data.get("data") or []
        url, params = data.get("next"), None
    return items


def _load_state() -> dict:
    try:
        return json.loads(STATE.read_text(encoding="utf8"))
    except (OSError, ValueError):
        return {"favorites": [], "playlists": {}}


def _save_state(state: dict):
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf8")
    tmp.replace(STATE)


def _ensure(track_id: str) -> str | None:
    """Path of a Deezer track in this library: downloaded (or linked) if needed."""
    key = f"dz:{track_id}"
    path = local_song.song_already_downloaded(key)
    if path:
        return path
    try:
        return download_song(Song.parse_deezer(_get(f"/track/{track_id}")))
    except Exception as e:
        print(f"[Deezer] ❌ {track_id}: {e}")
        return None


def sync() -> dict:
    deezer_id = (USER or {}).get("deezerId")
    if not deezer_id:
        raise RuntimeError("No Deezer profile for this user")
    state = _load_state()

    print("[Deezer] Coups de cœur…")
    favorites = [str(t["id"]) for t in _all(f"/user/{deezer_id}/tracks") if t.get("readable", True)]
    playlists = {}
    for p in _all(f"/user/{deezer_id}/playlists"):
        if p.get("is_loved_track"):
            continue  # the favorites, already above
        playlists[str(p["id"])] = {"name": p.get("title") or "Playlist",
                                   "tracks": [str(t["id"]) for t in _all(f"/playlist/{p['id']}/tracks")
                                              if t.get("readable", True)]}
    wanted = list(dict.fromkeys(favorites + [t for p in playlists.values() for t in p["tracks"]]))
    if not wanted and (state.get("favorites") or state.get("playlists")):
        # A profile turned private reads as empty: never take that as "remove everything".
        raise RuntimeError("Deezer returned nothing for this profile (is it still public?)")
    print(f"[Deezer] {len(favorites)} coups de cœur, {len(playlists)} playlists, {len(wanted)} sons")

    paths = {}
    for i, track_id in enumerate(wanted, 1):
        path = _ensure(track_id)
        if path:
            paths[track_id] = path
        if i % 25 == 0:
            print(f"[Deezer] {i}/{len(wanted)}")

    jellyfin.refresh_library()
    time.sleep(15)
    jellyfin.build_path_index()

    # Favorites: Deezer is the master.
    before = set(state.get("favorites") or [])
    for track_id in favorites:
        if track_id not in before and track_id in paths:
            jellyfin.add_to_favorite(paths[track_id])
    for track_id in before - set(favorites):
        song = local_song.get_song_by_id(f"dz:{track_id}")
        if song and song.local_path:
            jellyfin.remove_from_favorite(song.local_path)

    # Playlists: one Jellyfin playlist each, same songs in the same order.
    known = state.get("playlists") or {}
    for pid, p in playlists.items():
        jf_id = (known.get(pid) or {}).get("jellyfinId")
        if not jellyfin.jellyfin_playlist_exists(jf_id):
            jf_id = jellyfin.create_jellyfin_playlist(p["name"])
        current = [i["Id"] for i in jellyfin.get_jellyfin_playlist_items(jf_id)]
        target = [jellyfin.get_item_id_from_path(paths[t]) for t in p["tracks"] if t in paths]
        target = [t for t in dict.fromkeys(target) if t]
        for item_id in set(current) - set(target):
            jellyfin.remove_item_from_jellyfin_playlist(jf_id, item_id)
        for item_id in target:
            if item_id not in current:
                jellyfin.add_item_to_jellyfin_playlist(jf_id, item_id, skip_if_present=False)
        p["jellyfinId"] = jf_id
    for pid, old in known.items():
        if pid not in playlists and old.get("jellyfinId") and jellyfin.jellyfin_playlist_exists(old["jellyfinId"]):
            jellyfin.delete_jellyfin_playlist(old["jellyfinId"])

    # Songs neither liked nor in a playlist anymore leave this library (a friend's copy stays).
    keep = {f"dz:{t}" for t in wanted}
    removed = 0
    for song in local_song.all_songs():
        if song.spotify_id.startswith("dz:") and song.spotify_id not in keep:
            local_song.delete_song(song)
            removed += 1

    _save_state({"favorites": favorites, "playlists": playlists, "at": time.time()})
    print(f"[Deezer] ✅ {len(paths)}/{len(wanted)} sons dans la bibliothèque, {removed} retirés")
    return {"songs": len(paths), "missing": len(wanted) - len(paths), "removed": removed}
