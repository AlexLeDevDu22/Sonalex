"""
jellyfin.py – Client API Jellyfin

Gère l'authentification, les playlists, les favoris et l'index des fichiers.
"""

import requests
from dotenv import load_dotenv
import os
from PIL import Image
from io import BytesIO
import time
import json
from pathlib import Path

load_dotenv()

from config import JELLYFIN_URL

SERVER = JELLYFIN_URL
USER = os.getenv("JELLYFIN_USER")
PW = os.getenv("JELLYFIN_PW")
USER_ID = os.getenv("JELLYFIN_USER_ID")


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def authenticate():
    auth_data = {
        "username": USER,
        "Pw": PW,
    }
    authorization = 'MediaBrowser Client="Sonalex server", Device="Server", DeviceId="sonalex-server", Version="1.0"'
    headers = {"Authorization": authorization}
    response = requests.post(f"{SERVER}/Users/AuthenticateByName", headers=headers, json=auth_data)
    if response.status_code == 200:
        token = response.json().get("AccessToken")
        headers["Authorization"] = f'{authorization}, Token="{token}"'
        return headers
    else:
        print(response.text)
        raise Exception(f"Authentication failed on {SERVER}")


_AUTH_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jellyfin_auth.json")
TIMEOUT = 30

HEADERS = None
if os.path.exists(_AUTH_PATH):
    with open(_AUTH_PATH, "r", encoding="utf8") as f:
        HEADERS = json.load(f)
if not HEADERS:
    HEADERS = authenticate()
    with open(_AUTH_PATH, "w", encoding="utf8") as f:
        json.dump(HEADERS, f, indent=4, ensure_ascii=False)


def _ensure_auth():
    """Re-authenticate if the session token expired (401)."""
    global HEADERS
    HEADERS = authenticate()
    with open(_AUTH_PATH, "w", encoding="utf8") as f:
        json.dump(HEADERS, f, indent=4, ensure_ascii=False)


if not USER_ID:
    # Not in .env: the account the server signed in with.
    try:
        USER_ID = requests.get(f"{SERVER}/Users/Me", headers=HEADERS, timeout=TIMEOUT).json()["Id"]
    except Exception as e:
        print(f"[jellyfin] JELLYFIN_USER_ID introuvable : {e!r}")


def _get(url, raise_for_status=True, **kwargs):
    kwargs.setdefault("timeout", TIMEOUT)
    r = requests.get(url, headers=HEADERS, **kwargs)
    if r.status_code == 401:
        _ensure_auth()
        r = requests.get(url, headers=HEADERS, **kwargs)
    if raise_for_status:
        r.raise_for_status()
    return r


def _post(url, raise_for_status=True, **kwargs):
    kwargs.setdefault("timeout", TIMEOUT)
    r = requests.post(url, headers=HEADERS, **kwargs)
    if r.status_code == 401:
        _ensure_auth()
        r = requests.post(url, headers=HEADERS, **kwargs)
    if raise_for_status:
        r.raise_for_status()
    return r


def _delete(url, raise_for_status=True, **kwargs):
    kwargs.setdefault("timeout", TIMEOUT)
    r = requests.delete(url, headers=HEADERS, **kwargs)
    if r.status_code == 401:
        _ensure_auth()
        r = requests.delete(url, headers=HEADERS, **kwargs)
    if raise_for_status:
        r.raise_for_status()
    return r


# ---------------------------------------------------------------------------
# Bibliothèque
# ---------------------------------------------------------------------------

def get_music_library_id():
    r = _get(f"{SERVER}/Library/VirtualFolders")
    for lib in r.json():
        if lib.get("CollectionType") == "music":
            return lib["ItemId"]
    raise RuntimeError("Bibliothèque musique introuvable.")


def refresh_library(library_id=None):
    if library_id is None:
        library_id = get_music_library_id()
    _post(f"{SERVER}/Items/{library_id}/Refresh")


# ---------------------------------------------------------------------------
# Index des fichiers audio (chemin → jellyfin_item_id)
# ---------------------------------------------------------------------------

_ITEMS_BY_PATH: dict | None = None
_ITEMS_BY_SPOTIFY_ID: dict | None = None  # spotify_track_id → jellyfin_item_id


def build_path_index():
    global _ITEMS_BY_PATH
    r = _get(
        f"{SERVER}/Items",
        params={
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "Fields": "Path,ProviderIds",
            "Limit": 100000,
        },
    )
    _ITEMS_BY_PATH = {}
    for item in r.json()["Items"]:
        path = item.get("Path")
        if path:
            _ITEMS_BY_PATH[Path(path).as_posix()] = item["Id"]


def get_item_id_from_path(path: str, force: bool = False) -> str | None:
    global _ITEMS_BY_PATH
    if _ITEMS_BY_PATH is None or force:
        build_path_index()
    path = Path(path).as_posix()
    if path in _ITEMS_BY_PATH:
        return _ITEMS_BY_PATH[path]
    for p, item_id in _ITEMS_BY_PATH.items():
        if p.endswith(path) or path.endswith(p):
            return item_id
    return None


def get_item_id_from_spotify_track(spotify_track_id: str) -> str | None:
    """
    Résout l'ID Jellyfin d'une track à partir de son ID Spotify,
    en passant par tracks.json (qui stocke le chemin local).
    """
    import local_song  # import local pour éviter les circulaires (relit tracks.json s'il a changé)
    song = local_song.get_song_by_id(spotify_track_id)
    if not song or not song.local_path:
        return None
    return get_item_id_from_path(song.local_path)


# ---------------------------------------------------------------------------
# Playlists – lecture
# ---------------------------------------------------------------------------

def get_all_jellyfin_playlists() -> list[dict]:
    """Retourne toutes les playlists Jellyfin."""
    r = _get(
        f"{SERVER}/Items",
        params={
            "Recursive": True,
            "IncludeItemTypes": "Playlist",
        },
    )
    return r.json().get("Items", [])

def get_jellyfin_playlist_items(jellyfin_playlist_id: str) -> list[dict]:
    """Retourne les items (audio) d'une playlist Jellyfin, dans l'ordre (avec PlaylistItemId)."""
    r = _get(
        f"{SERVER}/Playlists/{jellyfin_playlist_id}/Items",
        params={
            "UserId": USER_ID,
            "Fields": "Path,ProviderIds",
        },
    )
    return r.json().get("Items", [])


def jellyfin_playlist_exists(jellyfin_playlist_id: str | None) -> bool:
    if not jellyfin_playlist_id:
        return False
    r = _get(f"{SERVER}/Items/{jellyfin_playlist_id}", raise_for_status=False, params={"userId": USER_ID})
    if r.status_code in (400, 404):
        return False
    r.raise_for_status()  # Jellyfin down / error: never conclude "deleted" from that
    return True


# ---------------------------------------------------------------------------
# Playlists – écriture
# ---------------------------------------------------------------------------

def create_jellyfin_playlist(name: str) -> str:
    """Crée une playlist vide dans Jellyfin et retourne son ID."""
    r = _post(
        f"{SERVER}/Playlists",
        params={
            "Name": name,
            "UserId": USER_ID,
            "MediaType": "Audio",
        },
    )
    playlist_id = r.json().get("Id")
    print(f"[Jellyfin] ✅ Playlist '{name}' créée (id={playlist_id})")
    return playlist_id


def delete_jellyfin_playlist(jellyfin_playlist_id: str):
    """Supprime une playlist Jellyfin."""
    _delete(f"{SERVER}/Items/{jellyfin_playlist_id}")
    print(f"[Jellyfin] 🗑 Playlist {jellyfin_playlist_id} supprimée")


def add_item_to_jellyfin_playlist(jellyfin_playlist_id: str, jellyfin_item_id: str,
                                  skip_if_present: bool = True) -> bool:
    """Ajoute un item audio à une playlist Jellyfin (sans créer de doublon par défaut)."""
    if skip_if_present and any(i["Id"] == jellyfin_item_id for i in get_jellyfin_playlist_items(jellyfin_playlist_id)):
        return True
    r = _post(
        f"{SERVER}/Playlists/{jellyfin_playlist_id}/Items",
        raise_for_status=False,
        params={
            "Ids": jellyfin_item_id,
            "UserId": USER_ID,
        },
    )
    if r.status_code not in (200, 204):
        print(f"[Jellyfin] ⚠️ Failed to add item {jellyfin_item_id} to playlist {jellyfin_playlist_id}: "
              f"{r.status_code} {r.text[:200]}")
        return False
    return True


def remove_item_from_jellyfin_playlist(jellyfin_playlist_id: str, jellyfin_item_id: str) -> bool:
    """Retire un item audio (toutes ses occurrences) d'une playlist Jellyfin.
    Jellyfin attend des PlaylistItemId (« entries ») ; en 10.11 ils valent l'id du morceau."""
    entries = list({i.get("PlaylistItemId") or i["Id"] for i in get_jellyfin_playlist_items(jellyfin_playlist_id)
                    if i["Id"] == jellyfin_item_id})
    if not entries:
        return True
    return remove_jellyfin_playlist_entries(jellyfin_playlist_id, entries)


def remove_jellyfin_playlist_entries(jellyfin_playlist_id: str, entry_ids: list[str]) -> bool:
    r = _delete(
        f"{SERVER}/Playlists/{jellyfin_playlist_id}/Items",
        raise_for_status=False,
        params={"EntryIds": ",".join(entry_ids), "UserId": USER_ID},
    )
    if r.status_code not in (200, 204):
        print(f"[Jellyfin] ⚠️  Failed to remove entries from playlist {jellyfin_playlist_id}: {r.status_code}")
        return False
    return True


def dedupe_jellyfin_playlist(jellyfin_playlist_id: str) -> int:
    """Retire les doublons d'une playlist. Jellyfin 10.11 renvoie PlaylistItemId == Id du morceau,
    donc retirer une « entry » retire toutes ses occurrences : on retire puis on rajoute une fois."""
    from collections import Counter
    counts = Counter(i["Id"] for i in get_jellyfin_playlist_items(jellyfin_playlist_id))
    dupes = [item_id for item_id, n in counts.items() if n > 1]
    for item_id in dupes:
        if remove_jellyfin_playlist_entries(jellyfin_playlist_id, [item_id]):
            add_item_to_jellyfin_playlist(jellyfin_playlist_id, item_id, skip_if_present=False)
    return sum(counts[i] - 1 for i in dupes)


def add_track_to_playlist_by_spotify_id(jellyfin_playlist_id: str, spotify_track_id: str) -> bool:
    """
    Ajoute une track dans une playlist Jellyfin en partant de son ID Spotify.
    Attendra jusqu'à 30 s que la bibliothèque indexe le fichier après téléchargement.
    """
    item_id = None
    for attempt in range(30):
        item_id = get_item_id_from_spotify_track(spotify_track_id)
        if item_id:
            break
        if attempt == 0:
            refresh_library()
        time.sleep(2)
        build_path_index()

    if not item_id:
        print(f"[Jellyfin] ⚠️  Item not found in Jellyfin for spotify track {spotify_track_id}")
        return False

    return add_item_to_jellyfin_playlist(jellyfin_playlist_id, item_id)


def remove_track_from_playlist_by_spotify_id(jellyfin_playlist_id: str, spotify_track_id: str) -> bool:
    """Retire une track d'une playlist Jellyfin en partant de son ID Spotify."""
    item_id = get_item_id_from_spotify_track(spotify_track_id)
    if not item_id:
        print(f"[Jellyfin] ⚠️  Item not found in Jellyfin for spotify track {spotify_track_id}")
        return False
    return remove_item_from_jellyfin_playlist(jellyfin_playlist_id, item_id)


# ---------------------------------------------------------------------------
# Favoris
# ---------------------------------------------------------------------------

def get_jellyfin_favorites() -> list[dict]:
    """Retourne les items audio favoris de l'utilisateur."""
    r = _get(
        f"{SERVER}/Items",
        params={
            "Recursive": True,
            "IncludeItemTypes": "Audio",
            "Filters": "IsFavorite",
            "Fields": "Path,ProviderIds",
            "UserId": USER_ID,
            "Limit": 100000,
        },
    )
    return r.json().get("Items", [])


def add_to_favorite(path: str):
    """Marque un fichier audio comme favori dans Jellyfin."""
    print("Adding", path, "to favorites...")
    item_id = None
    for attempt in range(30):
        item_id = get_item_id_from_path(path, force=attempt > 0)
        if item_id:
            break
        if attempt == 0:
            refresh_library()  # only when the file isn't indexed yet
        time.sleep(2)

    if not item_id:
        print(f"[Jellyfin] ⚠️  Could not find item for path: {path}")
        return

    _post(f"{SERVER}/Users/{USER_ID}/FavoriteItems/{item_id}")


def remove_from_favorite(path: str):
    """Retire un fichier audio des favoris Jellyfin."""
    item_id = get_item_id_from_path(path)
    if not item_id:
        print(f"[Jellyfin] ⚠️  Could not find item for path: {path}")
        return
    _delete(f"{SERVER}/Users/{USER_ID}/FavoriteItems/{item_id}")
    print(f"[Jellyfin] 💔 Removed favorite: {path}")


# ---------------------------------------------------------------------------
# Cover art
# ---------------------------------------------------------------------------

def upload_playlist_cover(playlist_name: str, image_url: str):
    """Télécharge une image depuis une URL et l'envoie comme cover de la playlist Jellyfin."""
    refresh_library()
    playlists = get_all_jellyfin_playlists()
    cover_id = None
    for playlist in playlists:
        if playlist["Name"] == playlist_name:
            cover_id = playlist["Id"]
            break
    if cover_id is None:
        raise ValueError(f"Playlist '{playlist_name}' introuvable.")

    response = requests.get(image_url, timeout=TIMEOUT)
    response.raise_for_status()
    img = Image.open(BytesIO(response.content))
    buf = BytesIO()
    img.convert("RGB").save(buf, format="JPEG")
    buf.seek(0)

    print(f"Changing cover for playlist {playlist_name}...")
    upload_headers = dict(HEADERS)
    upload_headers["Content-Type"] = "image/jpeg"
    for _ in range(30):
        upload = requests.post(
            f"{SERVER}/Items/{cover_id}/Images/Primary",
            headers=upload_headers,
            data=buf.getvalue(),
            timeout=TIMEOUT,
        )
        if upload.status_code == 200:
            print("Cover changed!")
            return True
        time.sleep(1)
    return False


if __name__ == "__main__":
    print([(playlist["Name"], playlist["Id"]) for playlist in get_all_jellyfin_playlists()])
