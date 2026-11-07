"""
spotify.py – Client Spotify API (lecture + écriture)

Utilise le token via chosic.com pour la lecture.
Les fonctions d'écriture (add/remove) nécessitent un token OAuth
avec les scopes playlist-modify-public, playlist-modify-private,
user-library-modify, user-library-read.
"""

import json
import os
import threading
from time import sleep, time

import requests
from dotenv import load_dotenv

load_dotenv()

_CHOSIC_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chosic_data.json")
try:
    with open(_CHOSIC_PATH, "r") as f:
        chosic_data = json.load(f)
except FileNotFoundError:
    # No Spotify account token: what doesn't need one (covers, the catalog with its own keys) works.
    chosic_data = {}

SPOTIFY_USER_ID = os.getenv("SPOTIFY_USER_ID")

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

_TOKEN_LOCK = threading.Lock()


def refresh_spotify_token(force: bool = False):
    """Refreshes the chosic access token when it's older than 1 h (or `force`). Retries on
    network errors: one SSL hiccup used to abort the whole nightly sync."""
    with _TOKEN_LOCK:
        # The API and the nightly sync are separate processes: pick up a token the other one
        # refreshed instead of refreshing again.
        try:
            with open(_CHOSIC_PATH) as f:
                on_disk = json.load(f)
            if (on_disk.get("last_refreshed") or 0) > (chosic_data.get("last_refreshed") or 0):
                chosic_data.update(on_disk)
                force = False
        except (OSError, ValueError):
            pass
        if not force and chosic_data.get("last_refreshed") and chosic_data["last_refreshed"] + 3300 > time():
            return chosic_data["access_token"]

        if not chosic_data.get("playlist_analyzer_refresh_token"):
            raise RuntimeError("Pas de jeton de compte Spotify : backend/chosic_data.json manquant "
                               "(voir backend/README.md, synchro Spotify)")
        url = "https://www.chosic.com/api/tools/refresh-user-token/"
        headers = {
            "User-Agent": "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:152.0) Gecko/20100101 Firefox/152.0",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Referer": "https://www.chosic.com/spotify-liked-songs-organizer/",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": "https://www.chosic.com",
            "Pragma": "no-cache",
            "Cache-Control": "no-cache",
        }
        cookies = {
            "pll_language": "en",
            "playlist_analyzer_refresh_token": chosic_data["playlist_analyzer_refresh_token"],
        }
        last_error = None
        for attempt in range(5):
            try:
                response = requests.post(url, headers=headers, cookies=cookies,
                                         data={"app": "playlist_analyzer"}, timeout=20)
                if response.status_code == 200:
                    chosic_data["last_refreshed"] = time()
                    chosic_data["access_token"] = response.json()["access_token"]
                    tmp = _CHOSIC_PATH + ".tmp"
                    with open(tmp, "w") as f:
                        json.dump(chosic_data, f, indent=4)
                    os.replace(tmp, _CHOSIC_PATH)
                    return chosic_data["access_token"]
                last_error = f"{response.status_code} {response.text[:200]}"
            except requests.RequestException as e:
                last_error = repr(e)
            sleep(2 * (attempt + 1))
        raise Exception("Failed to refresh Spotify token", last_error)


def _auth_headers():
    refresh_spotify_token()
    return {
        "Authorization": f"Bearer {chosic_data['access_token']}",
        "Content-Type": "application/json",
    }


def spotify_request(method: str, path: str, **kwargs) -> requests.Response:
    """Spotify Web API call with retries: network errors, 5xx, 429 (Retry-After) and an expired
    token (401 → refresh once)."""
    url = path if path.startswith("http") else f"https://api.spotify.com/v1{path}"
    refreshed = False
    response = None
    for attempt in range(5):
        try:
            response = requests.request(method, url, headers=_auth_headers(), timeout=20, **kwargs)
        except requests.RequestException:
            sleep(2 * (attempt + 1))
            continue
        if response.status_code == 401 and not refreshed:
            refresh_spotify_token(force=True)
            refreshed = True
            continue
        if response.status_code == 429:
            sleep(min(float(response.headers.get("Retry-After", "2")), 30))
            continue
        if response.status_code >= 500:
            sleep(2 * (attempt + 1))
            continue
        return response
    if response is None:
        raise requests.ConnectionError(f"Spotify unreachable: {method} {path}")
    return response


# ---------------------------------------------------------------------------
# Lecture – tracks likées
# ---------------------------------------------------------------------------

def _get_spotify_limited_liked_tracks(limit=50, offset=0):
    req = spotify_request("GET", f"/me/tracks?limit={limit}&offset={offset}")
    if req.status_code == 401:
        print("Tokens expired")
    return req


def get_spotify_liked_tracks(all=False):
    print("Getting liked tracks...")
    if all:
        all_tracks = []
        offset = 0
        while True:
            req = _get_spotify_limited_liked_tracks(limit=50, offset=offset)
            if req.status_code != 200:
                raise Exception("Failed to get liked tracks", req.status_code, req)
            tracks = req.json()["items"]
            all_tracks.extend(tracks)
            if len(tracks) < 50:
                break
            offset += 50
        return all_tracks
    else:
        return _get_spotify_limited_liked_tracks(limit=50, offset=0)


# ---------------------------------------------------------------------------
# Lecture – playlists
# ---------------------------------------------------------------------------

def get_spotify_playlists():
    playlists, url = [], f"/users/{SPOTIFY_USER_ID}/playlists?limit=50"
    while url:
        data = spotify_request("GET", url).json()
        playlists += data.get("items", [])
        url = data.get("next")
    return playlists


def get_spotify_playlist_info(playlist_id):
    return spotify_request("GET", f"/playlists/{playlist_id}").json()


def get_spotify_track_info(track_id):
    return spotify_request("GET", f"/tracks/{track_id}").json()


def get_spotify_tracks(track_ids: list[str]) -> list[dict]:
    """Full track objects for many ids (50 per request)."""
    out = []
    for i in range(0, len(track_ids), 50):
        r = spotify_request("GET", "/tracks", params={"ids": ",".join(track_ids[i:i + 50])})
        r.raise_for_status()
        out += [t for t in r.json().get("tracks", []) if t]
    return out


def get_artist_info(artist_id):
    if not artist_id:
        return {}
    r = spotify_request("GET", f"/artists/{artist_id}")
    return r.json() if r.ok else {}


def get_spotify_playlist_tracks(playlist_id, all=False, offset=0, limit=50):
    if all:
        all_tracks = []
        offset = 0
        while True:
            tracks = get_spotify_playlist_tracks(playlist_id, all=False, limit=50, offset=offset)
            all_tracks.extend(tracks)
            if len(tracks) < 50:
                break
            offset += 50
        return all_tracks

    req = spotify_request("GET", f"/playlists/{playlist_id}/items?offset={offset}&limit={limit}")
    req.raise_for_status()
    return req.json()["items"]


# ---------------------------------------------------------------------------
# Écriture – tracks likées
# ---------------------------------------------------------------------------

def add_to_spotify_liked(track_id: str) -> bool:
    """Ajoute un track aux titres likés Spotify de l'utilisateur."""
    req = spotify_request("PUT", "/me/tracks", json={"ids": [track_id]})
    if req.status_code not in (200, 201):
        print(f"[Spotify] Failed to like track {track_id}: {req.status_code} {req.text}")
        return False
    print(f"[Spotify] ❤️  Track {track_id} liked")
    return True

def remove_from_spotify_liked(track_id: str) -> bool:
    """Retire un track des titres likés Spotify de l'utilisateur."""
    req = spotify_request("DELETE", "/me/tracks", json={"ids": [track_id]})
    if req.status_code not in (200, 204):
        print(f"[Spotify] Failed to unlike track {track_id}: {req.status_code} {req.text}")
        return False
    print(f"[Spotify] 💔 Track {track_id} unliked")
    return True


# ---------------------------------------------------------------------------
# Écriture – playlists
# ---------------------------------------------------------------------------

def _playlist_write(method: str, playlist_id: str, track_ids: list[str]) -> requests.Response:
    """POST/DELETE on a playlist's items. Spotify renamed /tracks → /items (Feb 2026); try the
    new endpoint first and fall back to the legacy one if this token isn't allowed on it."""
    uris = [f"spotify:track:{t}" for t in track_ids]
    if method == "POST":
        bodies = [("items", {"uris": uris}), ("tracks", {"uris": uris})]
    else:
        bodies = [("items", {"items": [{"uri": u} for u in uris]}),
                  ("tracks", {"tracks": [{"uri": u} for u in uris]})]
    req = None
    for endpoint, body in bodies:
        req = spotify_request(method, f"/playlists/{playlist_id}/{endpoint}", json=body)
        if req.status_code not in (403, 404, 405, 410):
            return req
    return req


def add_tracks_to_spotify_playlist(playlist_id: str, track_ids: list[str]) -> bool:
    """Adds tracks (in order, at the end) to a Spotify playlist, 100 per request."""
    for i in range(0, len(track_ids), 100):
        req = _playlist_write("POST", playlist_id, track_ids[i:i + 100])
        if req.status_code not in (200, 201):
            print(f"[Spotify] Failed to add {len(track_ids)} tracks to playlist {playlist_id}: {req.status_code} {req.text}")
            req.raise_for_status()
    print(f"[Spotify] ➕ {len(track_ids)} track(s) added to playlist {playlist_id}")
    return True


def remove_tracks_from_spotify_playlist(playlist_id: str, track_ids: list[str]) -> bool:
    """Removes every occurrence of these tracks from a Spotify playlist, 100 per request."""
    for i in range(0, len(track_ids), 100):
        req = _playlist_write("DELETE", playlist_id, track_ids[i:i + 100])
        if req.status_code not in (200, 204):
            print(f"[Spotify] Failed to remove tracks from playlist {playlist_id}: {req.status_code} {req.text}")
            req.raise_for_status()
    print(f"[Spotify] ➖ {len(track_ids)} track(s) removed from playlist {playlist_id}")
    return True


def add_track_to_spotify_playlist(playlist_id: str, track_id: str) -> bool:
    """Ajoute un track à une playlist Spotify."""
    return add_tracks_to_spotify_playlist(playlist_id, [track_id])


def remove_track_from_spotify_playlist(playlist_id: str, track_id: str) -> bool:
    """Retire un track d'une playlist Spotify."""
    return remove_tracks_from_spotify_playlist(playlist_id, [track_id])


# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------

def create_spotify_playlist(name: str, public: bool = False) -> dict:
    """Creates a playlist on the user's Spotify account; returns the playlist object."""
    req = spotify_request("POST", f"/users/{SPOTIFY_USER_ID}/playlists",
                          json={"name": name, "public": public, "description": "Créée depuis Musique (Jellyfin)"})
    req.raise_for_status()
    return req.json()


def rename_spotify_playlist(playlist_id: str, name: str) -> bool:
    req = spotify_request("PUT", f"/playlists/{playlist_id}", json={"name": name})
    if req.status_code not in (200, 204):
        print(f"[Spotify] Failed to rename playlist {playlist_id}: {req.status_code} {req.text}")
        return False
    return True


def download_online_cover_image(online_cover_image_path, temp_file="temp_cover.jpg"):
    """Télécharge l'image de couverture depuis l'URL fournie."""
    response = requests.get(online_cover_image_path, timeout=20)
    with open(temp_file, "wb") as f:
        f.write(response.content)
    return temp_file
