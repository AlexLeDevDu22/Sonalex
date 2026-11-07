"""
live_sync.py – Pushes Jellyfin changes to Spotify right away (Jellyfin is the master).

Used by the API (api/live_worker.py) as soon as something changes, and by the nightly sync
before it reads Spotify. Every function here must be called with the sync lock held
(sync_lock.sync_lock) and reloads the state from disk first.

What is pushed:
  - favorites  → Spotify liked songs (like / unlike);
  - playlist content → added / removed tracks on the Spotify playlist (if we can edit it);
  - playlist renamed in Jellyfin → renamed on Spotify;
  - playlist created in Jellyfin → created on Spotify and synced from then on;
  - playlist deleted in Jellyfin → no longer synced (the Spotify playlist is kept, never deleted).

Only songs known in tracks.json (i.e. with a Spotify id) are synced. A song missing from
Jellyfin (being rescanned, file moved…) is never treated as "removed": only an item that
exists in Jellyfin and is not favorite / not in the playlist counts as a removal.
"""

import json
import os
from pathlib import Path

import jellyfin
import local_song
from config import DATA_DIR
import playlists
import spotify

PENDING_CLEANUP_PATH = str(DATA_DIR / "pending_cleanup.json")


def log(*args):
    print("[live-sync]", *args, flush=True)


# ---------------------------------------------------------------------------
# Jellyfin item ↔ Spotify id
# ---------------------------------------------------------------------------

def _path_index() -> dict[str, str]:
    """Normalized file path → Spotify id, from tracks.json (reloaded if it changed)."""
    return {Path(s.local_path).as_posix(): s.spotify_id for s in local_song.all_songs() if s.local_path}


def _library_items() -> list[dict]:
    """Every audio item of the user, with its path and favorite flag."""
    r = jellyfin._get(f"{jellyfin.SERVER}/Items", params={
        "Recursive": "true", "IncludeItemTypes": "Audio", "Fields": "Path",
        "UserId": jellyfin.USER_ID, "EnableUserData": "true", "Limit": 100000,
    })
    return r.json().get("Items", [])


def _playlist_spotify_ids(jf_playlist_id: str, path_to_sid: dict) -> list[str]:
    """Spotify ids of a Jellyfin playlist, in order, without duplicates."""
    out, seen = [], set()
    for item in jellyfin.get_jellyfin_playlist_items(jf_playlist_id):
        sid = path_to_sid.get(Path(item.get("Path") or "").as_posix())
        if sid and sid not in seen:
            seen.add(sid)
            out.append(sid)
    return out


# ---------------------------------------------------------------------------
# Songs to delete later (unliked and in no playlist): done by the nightly sync, which
# double-checks — so an accidental unlike can be undone during the day.
# ---------------------------------------------------------------------------

def _queue_cleanup(track_ids):
    if not track_ids:
        return
    try:
        with open(PENDING_CLEANUP_PATH, encoding="utf8") as f:
            pending = set(json.load(f))
    except (FileNotFoundError, ValueError):
        pending = set()
    pending |= set(track_ids)
    tmp = PENDING_CLEANUP_PATH + ".tmp"
    with open(tmp, "w", encoding="utf8") as f:
        json.dump(sorted(pending), f)
    os.replace(tmp, PENDING_CLEANUP_PATH)


def take_pending_cleanup() -> set[str]:
    try:
        with open(PENDING_CLEANUP_PATH, encoding="utf8") as f:
            pending = set(json.load(f))
    except (FileNotFoundError, ValueError):
        return set()
    os.remove(PENDING_CLEANUP_PATH)
    return pending


# ---------------------------------------------------------------------------
# Favorites
# ---------------------------------------------------------------------------

def _likes_state() -> dict:
    state = playlists.PLAYLISTS_JSON
    if "likes" not in state:
        state["likes"] = {"name": "❤️", "id": "likes", "jellyfin_id": None, "editable": True,
                          "snapshot_id": "", "tracks": []}
    return state["likes"]


def push_favorites(items: list[dict] | None = None) -> int:
    """Diffs Jellyfin favorites against the likes state and likes / unlikes on Spotify.
    `items`: Jellyfin audio items with UserData (all of them when None). Returns the change count."""
    playlists.reload_state()
    path_to_sid = _path_index()
    likes = _likes_state()
    liked = list(likes["tracks"])
    liked_set = set(liked)
    added, removed = [], []
    for item in items if items is not None else _library_items():
        sid = path_to_sid.get(Path(item.get("Path") or "").as_posix())
        if not sid:
            continue
        fav = bool((item.get("UserData") or {}).get("IsFavorite"))
        if fav and sid not in liked_set:
            added.append(sid)
        elif not fav and sid in liked_set:
            removed.append(sid)

    for sid in added:
        if spotify.add_to_spotify_liked(sid):
            liked.append(sid)
            liked_set.add(sid)
    for sid in removed:
        if spotify.remove_from_spotify_liked(sid):
            liked.remove(sid)
            liked_set.discard(sid)
    if added or removed:
        likes["tracks"] = liked
        playlists._save_playlist_file()
        _queue_cleanup(removed)
        log(f"favoris → Spotify : +{len(added)} −{len(removed)}")
    return len(added) + len(removed)


def push_favorite_items(item_ids: list[str]) -> int:
    """Favorites changed on these Jellyfin items (from the websocket)."""
    items = []
    for item_id in item_ids:
        r = jellyfin._get(f"{jellyfin.SERVER}/Items", raise_for_status=False, params={
            "Ids": item_id, "Fields": "Path", "UserId": jellyfin.USER_ID, "EnableUserData": "true"})
        if r.ok:
            items += [i for i in r.json().get("Items", []) if i.get("Type") == "Audio"]
    return push_favorites(items) if items else 0


# ---------------------------------------------------------------------------
# Playlists
# ---------------------------------------------------------------------------

def _state_key_for(jf_playlist_id: str) -> str | None:
    for key, data in playlists.PLAYLISTS_JSON.items():
        if key != "likes" and data.get("jellyfin_id") == jf_playlist_id:
            return key
    return None


def push_playlist(jf_playlist_id: str, jf_name: str | None = None,
                  existing_paths: set[str] | None = None) -> str:
    """Pushes one Jellyfin playlist to Spotify. Returns a short summary."""
    playlists.reload_state()
    state = playlists.PLAYLISTS_JSON
    key = _state_key_for(jf_playlist_id)

    if not jellyfin.jellyfin_playlist_exists(jf_playlist_id):
        if key and not state[key].get("untracked"):
            # Deleted in Jellyfin: stop syncing it. The Spotify playlist is never deleted, and the
            # tombstone keeps the nightly sync from re-creating it in Jellyfin.
            state[key].update({"untracked": True, "jellyfin_id": None, "tracks": []})
            playlists._save_playlist_file()
            log(f"playlist « {state[key]['name']} » supprimée dans Jellyfin → plus synchronisée")
            return "untracked"
        return "gone"

    if key and state[key].get("untracked"):
        return "untracked"

    if jf_name is None:
        r = jellyfin._get(f"{jellyfin.SERVER}/Items/{jf_playlist_id}", params={"userId": jellyfin.USER_ID})
        jf_name = r.json().get("Name") or "Playlist"

    path_to_sid = _path_index()
    current = _playlist_spotify_ids(jf_playlist_id, path_to_sid)

    if key is None:
        # New playlist made in Jellyfin (the app): create it on Spotify.
        created = spotify.create_spotify_playlist(jf_name)
        key = created["id"]
        state[key] = {"tracks": [], "name": jf_name, "id": key, "jellyfin_id": jf_playlist_id,
                      "editable": True, "snapshot_id": created.get("snapshot_id", "")}
        playlists._save_playlist_file()  # saved right away: never create it twice
        log(f"nouvelle playlist « {jf_name} » → créée sur Spotify ({key})")

    data = state[key]
    previous = list(data.get("tracks", []))
    prev_set, cur_set = set(previous), set(current)
    added = [t for t in current if t not in prev_set]
    removed = [t for t in previous if t not in cur_set]

    # A track whose song isn't in Jellyfin right now (rescan, moved file) isn't "removed".
    if removed:
        if existing_paths is None:
            jellyfin.build_path_index()
            existing_paths = set(jellyfin._ITEMS_BY_PATH or {})
        sid_to_path = {sid: p for p, sid in path_to_sid.items()}
        removed = [t for t in removed if sid_to_path.get(t) in existing_paths]

    if data.get("editable"):
        if jf_name and jf_name.strip() != (data.get("name") or "").strip():
            spotify.rename_spotify_playlist(key, jf_name)
            log(f"« {data.get('name')} » renommée « {jf_name} » sur Spotify")
        if added:
            spotify.add_tracks_to_spotify_playlist(key, added)
        if removed:
            spotify.remove_tracks_from_spotify_playlist(key, removed)

    removed_set = set(removed)
    new_tracks = [t for t in previous if t not in removed_set] + added
    changed = bool(added or removed or (jf_name or "").strip() != (data.get("name") or "").strip())
    data["tracks"] = new_tracks
    data["name"] = jf_name or data.get("name")
    if changed:
        playlists._save_playlist_file()
        _queue_cleanup(removed)
        log(f"« {data['name']} » → Spotify : +{len(added)} −{len(removed)}"
            + ("" if data.get("editable") else " (playlist non modifiable sur Spotify : état local seulement)"))
    return f"+{len(added)} -{len(removed)}"


def reconcile() -> None:
    """Full Jellyfin → Spotify pass: favorites, every playlist, new and deleted playlists."""
    playlists.reload_state()
    items = _library_items()
    existing_paths = {Path(i["Path"]).as_posix() for i in items if i.get("Path")}
    push_favorites(items)

    jf_playlists = jellyfin.get_all_jellyfin_playlists()
    live_ids = {p["Id"] for p in jf_playlists}
    for p in jf_playlists:
        try:
            push_playlist(p["Id"], p.get("Name"), existing_paths)
        except Exception as e:
            log(f"⚠️ playlist « {p.get('Name')} » : {e!r}")

    # Tracked playlists that disappeared from Jellyfin.
    playlists.reload_state()
    for key, data in list(playlists.tracked_playlists().items()):
        if data.get("jellyfin_id") and data["jellyfin_id"] not in live_ids:
            push_playlist(data["jellyfin_id"])
