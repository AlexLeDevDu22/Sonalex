"""
playlists.py – Gestion des playlists via l'API Jellyfin

Le fichier playlists.json est la source de vérité locale.
Format d'une entrée :
{
  "spotify_id": {
    "name": "Ma Playlist",
    "id": "spotify_id",
    "jellyfin_id": "jellyfin_uuid",
    "snapshot_id": "abc123",
    "editable": true,
    "tracks": ["spotify_track_id_1", ...]
  }
}
"""

import json
import os
from dotenv import load_dotenv

from config import CONFIG
from spotify import get_spotify_playlist_info, get_spotify_playlist_tracks
import local_song
from song import Song
from downloading import download_song
from jellyfin import (
    create_jellyfin_playlist,
    delete_jellyfin_playlist,
    add_track_to_playlist_by_spotify_id,
    remove_track_from_playlist_by_spotify_id,
    upload_playlist_cover,
    refresh_library,
    get_music_library_id,
)

load_dotenv()
SPOTIFY_USER_ID = os.getenv("SPOTIFY_USER_ID")

# ---------------------------------------------------------------------------
# Chargement de l'état local
# ---------------------------------------------------------------------------

_PLAYLISTS_PATH = CONFIG.get("PATHS", "PLAYLISTS_JSON")
PLAYLISTS_JSON: dict = {}


def reload_state():
    """Re-reads playlists.json in place (other modules hold a reference to PLAYLISTS_JSON).
    Call it right after taking the sync lock: the other process may have changed the file."""
    try:
        with open(_PLAYLISTS_PATH, "r", encoding="utf8") as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {}
    PLAYLISTS_JSON.clear()
    PLAYLISTS_JSON.update(data)
    return PLAYLISTS_JSON


reload_state()


def _save_playlist_file():
    """Atomic write: a crash mid-write must never leave a truncated playlists.json."""
    tmp = _PLAYLISTS_PATH + ".tmp"
    with open(tmp, "w", encoding="utf8") as f:
        json.dump(PLAYLISTS_JSON, f, indent=4, ensure_ascii=False)
    os.replace(tmp, _PLAYLISTS_PATH)


def tracked_playlists() -> dict:
    """Playlists synced both ways (not the likes, not the untracked ones)."""
    return {k: v for k, v in PLAYLISTS_JSON.items() if k != "likes" and not v.get("untracked")}


# ---------------------------------------------------------------------------
# Cache Spotify
# ---------------------------------------------------------------------------

class SpotifyPlaylistCache:
    """Lazy loader pour les tracks d'une playlist Spotify."""

    def __init__(self, playlist_id):
        self.playlist_id = playlist_id
        info = get_spotify_playlist_info(playlist_id)
        if not info.get("name"):
            print(json.dumps(info, indent=4))
        self.name = info["name"]
        self.total_lenght = info["tracks"]["total"]
        self.snapshot_id = info["snapshot_id"]
        self.editable = info["collaborative"] or info["owner"]["id"] == SPOTIFY_USER_ID
        self.tracks = []

    def __getitem__(self, i):
        limit = 50
        offset = len(self.tracks)
        while len(self.tracks) <= i:
            tracks = get_spotify_playlist_tracks(self.playlist_id, offset=offset, limit=limit)
            self.tracks += tracks
            offset += limit
        return self.tracks[i]

    def __len__(self):
        return len(self.tracks)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def has_playlist_changed(cache: SpotifyPlaylistCache) -> bool:
    reel_snapshot = cache.snapshot_id
    current_snapshot = PLAYLISTS_JSON[cache.playlist_id]["snapshot_id"]
    reel_last_id = cache[0]
    current_last_id = None
    if len(PLAYLISTS_JSON[cache.playlist_id]["tracks"]) > 0:
        current_last_id = PLAYLISTS_JSON[cache.playlist_id]["tracks"][-1]
    return reel_snapshot != current_snapshot and (
        lenght_difference(cache) != 0 or reel_last_id != current_last_id
    )


def lenght_difference(cache: SpotifyPlaylistCache):
    current_len = len(PLAYLISTS_JSON[cache.playlist_id]["tracks"])
    if not CONFIG.getboolean("PROCESS", "ONLY_LIKED") or cache.playlist_id == "likes":
        reel_len = cache.total_lenght
    else:
        reel_len = 0
        for i in range(cache.total_lenght):
            track_id = cache[i]["track"]["id"]
            if track_id in PLAYLISTS_JSON["likes"]["tracks"]:
                reel_len += 1
    print(str(current_len) + "/" + str(reel_len))
    return reel_len - current_len


def is_track_in_any_playlist(song_id: str) -> bool:
    for p_id, playlist in PLAYLISTS_JSON.items():
        for track_id in playlist["tracks"]:
            if track_id == song_id:
                return True
    return False


# ---------------------------------------------------------------------------
# Ajout / suppression de tracks
# ---------------------------------------------------------------------------

def add_to_playlist(playlist_id: str, track_id: str, track_path: str):
    """Ajoute une track à la playlist (JSON local + API Jellyfin)."""
    global PLAYLISTS_JSON

    if track_id in PLAYLISTS_JSON[playlist_id]["tracks"]:
        return

    jellyfin_id = PLAYLISTS_JSON[playlist_id].get("jellyfin_id")
    if jellyfin_id:
        add_track_to_playlist_by_spotify_id(jellyfin_id, track_id)

    PLAYLISTS_JSON[playlist_id]["tracks"].append(track_id)
    print(f"{track_id} added to playlist {playlist_id}")
    _save_playlist_file()


def add_track(song: Song, playlist_id):
    """Télécharge (si besoin) et ajoute une song à la playlist."""
    track_path = local_song.song_already_downloaded(song.spotify_id)
    if track_path:
        print("Song already downloaded, adding to playlist")
    else:
        if not CONFIG.getboolean("PROCESS", "ONLY_LIKED") or playlist_id == "likes":
            print("Downloading song " + song.title + " - " + song.artist)
            track_path = download_song(song)
        else:
            print("Song not downloaded because ONLY_LIKED is enabled and this song is not in likes playlist")
            return
    add_to_playlist(playlist_id, song.spotify_id, track_path)


def remove_playlist_track(playlist_id: str, song_id: str):
    """Retire une song de la playlist (JSON local + API Jellyfin) et supprime le fichier si orphellin."""
    global PLAYLISTS_JSON

    title_artist = None
    playlist_name = PLAYLISTS_JSON[playlist_id]["name"]

    for i in range(len(PLAYLISTS_JSON[playlist_id]["tracks"])):
        if PLAYLISTS_JSON[playlist_id]["tracks"][i] == song_id:
            song = local_song.get_song_by_id(song_id)
            if song:
                title_artist = (song.title or "") + " - " + (song.artist or "")

            del PLAYLISTS_JSON[playlist_id]["tracks"][i]
            print(f"WELL REMOVED {song_id}")
            break

    # Retirer de la playlist Jellyfin
    jellyfin_id = PLAYLISTS_JSON[playlist_id].get("jellyfin_id")
    if jellyfin_id:
        remove_track_from_playlist_by_spotify_id(jellyfin_id, song_id)

    _save_playlist_file()

    if title_artist and playlist_name:
        print(f"Song {title_artist} removed from {playlist_name}")

    if not is_track_in_any_playlist(song_id):
        song = local_song.get_song_by_id(song_id)
        if song:
            local_song.delete_song(song)


# ---------------------------------------------------------------------------
# Update Spotify → Jellyfin
# ---------------------------------------------------------------------------

def update_by_removed_songs(cache: SpotifyPlaylistCache):
    global PLAYLISTS_JSON
    max_lenght = cache.total_lenght
    i = 0
    while lenght_difference(cache) < 0 and i < max_lenght:
        reel_id = cache[i]["track"]["id"]
        current_id = PLAYLISTS_JSON[cache.playlist_id]["tracks"][i]
        if reel_id != current_id:
            remove_playlist_track(cache.playlist_id, current_id)
        else:
            i += 1


def update_by_removed_and_added_songs(cache: SpotifyPlaylistCache):
    global PLAYLISTS_JSON
    for track_id in list(PLAYLISTS_JSON[cache.playlist_id]["tracks"]):
        is_in = False
        for i in range(cache.total_lenght):
            if track_id == cache[i]["track"]["id"]:
                is_in = True
                break
        if not is_in:
            remove_playlist_track(cache.playlist_id, track_id)
    update_by_added_songs(cache)


def update_by_added_songs(cache: SpotifyPlaylistCache):  # Recursive
    global PLAYLISTS_JSON
    num_added = lenght_difference(cache)
    if num_added <= 0:
        return

    new_track = cache[num_added - 1]
    if CONFIG.getboolean("PROCESS", "ONLY_LIKED") and cache.playlist_id != "likes":
        while new_track["track"]["id"] not in PLAYLISTS_JSON["likes"]["tracks"]:
            num_added -= 1
            if num_added <= 0:
                return
            new_track = cache[num_added - 1]

    if not new_track["track"] or not new_track["track"]["name"]:
        print("no data for this song - WTF")
        return

    t = new_track["track"]
    add_track(
        Song.parse_spotify(t),
        cache.playlist_id,
    )
    update_by_added_songs(cache)


def check_update(playlist_id: str):
    """Vérifie et applique les changements Spotify → Jellyfin pour une playlist."""
    cache = SpotifyPlaylistCache(playlist_id)

    if not has_playlist_changed(cache):
        print("No update for playlist : " + cache.name)
        return

    diff = lenght_difference(cache)
    if diff < 0:
        update_by_removed_songs(cache)
    elif diff == 0:
        update_by_removed_and_added_songs(cache)
    else:
        update_by_added_songs(cache)

    PLAYLISTS_JSON[playlist_id]["snapshot_id"] = cache.snapshot_id
    del cache
    _save_playlist_file()


# ---------------------------------------------------------------------------
# Création / suppression de playlists
# ---------------------------------------------------------------------------

def create_playlist(name: str, id_: str, snapshot_id: str, editable: bool = True):
    """Crée une playlist dans Jellyfin et l'enregistre dans le JSON local."""
    global PLAYLISTS_JSON

    if id_ in PLAYLISTS_JSON:
        return  # déjà existante

    print(f"Creating Playlist {name}")

    # Rafraîchir la bibliothèque pour s'assurer que Jellyfin est à jour
    refresh_library(get_music_library_id())

    # Créer via l'API Jellyfin
    jellyfin_id = create_jellyfin_playlist(name)

    PLAYLISTS_JSON[id_] = {
        "tracks": [],
        "name": name,
        "id": id_,
        "jellyfin_id": jellyfin_id,
        "editable": editable,
        "snapshot_id": snapshot_id,
    }
    _save_playlist_file()


def delete_playlist(playlist_id: str, remove_songs: bool = True):
    """Supprime une playlist de Jellyfin et du JSON local."""
    print(f"Removing playlist {playlist_id}")

    jellyfin_id = PLAYLISTS_JSON[playlist_id].get("jellyfin_id")
    if jellyfin_id:
        delete_jellyfin_playlist(jellyfin_id)

    if remove_songs:
        for track_id in list(PLAYLISTS_JSON[playlist_id]["tracks"]):
            remove_playlist_track(playlist_id, track_id)

    del PLAYLISTS_JSON[playlist_id]
    _save_playlist_file()


# ---------------------------------------------------------------------------
# Accesseurs
# ---------------------------------------------------------------------------

def get_playlist(playlist_id: str) -> dict | None:
    return PLAYLISTS_JSON.get(playlist_id)


def list_playlists() -> list:
    return list(PLAYLISTS_JSON.keys())

# ---------------------------------------------------------------------------
# Order: Jellyfin playlists in the playlist's real (Spotify) order
# ---------------------------------------------------------------------------

def reorder_like_spotify(sp_id: str, force: bool = False) -> int:
    """Puts the Jellyfin playlist in the Spotify playlist's order (songs that aren't on Spotify
    keep their place at the end). Only when the Spotify playlist changed since the last time
    (snapshot id) or the Jellyfin side has other songs. Returns the number of moves."""
    from pathlib import Path

    import jellyfin
    from spotify import get_spotify_playlist_info, get_spotify_playlist_tracks

    data = PLAYLISTS_JSON.get(sp_id)
    if not data or not data.get("jellyfin_id") or data.get("untracked"):
        return 0
    jf_id = data["jellyfin_id"]
    items = jellyfin.get_jellyfin_playlist_items(jf_id)
    ids_now = [i["Id"] for i in items]
    snapshot = get_spotify_playlist_info(sp_id).get("snapshot_id")
    if not force and data.get("orderedSnapshot") == snapshot and data.get("orderedItems") == ids_now:
        return 0

    by_path = {Path(s.local_path).as_posix(): s.spotify_id for s in local_song.all_songs() if s.local_path}
    rank = {}
    for n, entry in enumerate(get_spotify_playlist_tracks(sp_id, all=True)):
        track = entry.get("track") or entry.get("item") or {}
        if track.get("id"):
            rank.setdefault(track["id"], n)
    current = [(i.get("PlaylistItemId") or i["Id"], by_path.get(Path(i.get("Path") or "").as_posix())) for i in items]
    target = sorted(range(len(current)), key=lambda k: (rank.get(current[k][1], 10**6), k))
    target_ids = [current[k][0] for k in target]

    moves = 0
    order = [c[0] for c in current]
    for pos, entry_id in enumerate(target_ids):
        if order[pos] == entry_id:
            continue
        jellyfin._post(f"{jellyfin.SERVER}/Playlists/{jf_id}/Items/{entry_id}/Move/{pos}")
        order.remove(entry_id)
        order.insert(pos, entry_id)
        moves += 1
    data["orderedSnapshot"] = snapshot
    data["orderedItems"] = [i["Id"] for i in jellyfin.get_jellyfin_playlist_items(jf_id)]
    _save_playlist_file()
    if moves:
        print(f"[Ordre] « {data.get('name')} » : {moves} déplacement(s) pour suivre l'ordre Spotify")
    return moves


def reorder_all_like_spotify() -> int:
    reload_state()
    total = 0
    for sp_id in list(tracked_playlists()):
        try:
            total += reorder_like_spotify(sp_id)
        except Exception as e:
            print(f"[Ordre] ⚠️ {PLAYLISTS_JSON.get(sp_id, {}).get('name')} : {e!r}")
    return total
