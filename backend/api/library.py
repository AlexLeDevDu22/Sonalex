"""
library.py – What is already in the Jellyfin library.

Downloaded songs are listed in tracks.json (spotify id → title/artist/path) and Jellyfin knows
them by path. This module joins the two so any online result can be swapped for the local copy.
"""

import json
import random
import threading
import time
from pathlib import Path

import requests

from .common import JELLYFIN_URL, TRACKS_JSON, normalize, song_signature

ITEM_FIELDS = "Genres,DateCreated,ChildCount"


def admin_headers(refresh: bool = False) -> dict:
    """Headers of the backend's own Jellyfin session (jellyfin_auth.json, re-auth on demand)."""
    import jellyfin  # existing module: authenticates at import

    if refresh:
        jellyfin._ensure_auth()
    return dict(jellyfin.HEADERS)


def jf_request(method: str, path: str, *, headers: dict | None = None, admin: bool = False, **kwargs):
    h = admin_headers() if admin else (headers or {})
    r = requests.request(method, f"{JELLYFIN_URL}{path}", headers=h, timeout=20, **kwargs)
    if r.status_code == 401 and admin:
        r = requests.request(method, f"{JELLYFIN_URL}{path}", headers=admin_headers(refresh=True), timeout=20, **kwargs)
    return r


class Library:
    def __init__(self):
        self._lock = threading.Lock()
        self._tracks_mtime = 0.0
        self.by_sid: dict[str, dict] = {}
        self.by_sig: dict[str, str] = {}
        self.by_artist: dict[str, list[str]] = {}
        self._path_to_item: dict[str, str] = {}
        self._index_time = 0.0

    # -- tracks.json -------------------------------------------------------

    def _reload_tracks(self):
        try:
            mtime = TRACKS_JSON.stat().st_mtime
        except FileNotFoundError:
            return
        if mtime == self._tracks_mtime:
            return
        data = json.loads(TRACKS_JSON.read_text(encoding="utf8"))
        by_sig, by_artist = {}, {}
        for sid, t in data.items():
            by_sig[song_signature(t.get("title"), t.get("artist"))] = sid
            for name in [t.get("artist")] + list(t.get("featured_artists") or []):
                if name:
                    by_artist.setdefault(normalize(name), []).append(sid)
        self.by_sid, self.by_sig, self.by_artist = data, by_sig, by_artist
        self._tracks_mtime = mtime

    # -- Jellyfin path index ----------------------------------------------

    def _reload_index(self, force: bool = False):
        if not force and time.time() - self._index_time < 300:
            return
        r = jf_request("GET", "/Items", admin=True, params={
            "Recursive": "true", "IncludeItemTypes": "Audio", "Fields": "Path", "Limit": 100000,
        })
        r.raise_for_status()
        self._path_to_item = {Path(i["Path"]).as_posix(): i["Id"] for i in r.json().get("Items", []) if i.get("Path")}
        self._index_time = time.time()

    def refresh(self, force_index: bool = False):
        with self._lock:
            self._reload_tracks()
            try:
                self._reload_index(force=force_index)
            except Exception as e:  # Jellyfin briefly unavailable: keep the old index
                print("[library] index refresh failed:", e)

    # -- Lookups ------------------------------------------------------------

    def local_sid(self, track: dict) -> str | None:
        key = track.get("key", "")
        if key.startswith("sp:") and key[3:] in self.by_sid:
            return key[3:]
        artist = track["artists"][0]["name"] if track.get("artists") else ""
        return self.by_sig.get(song_signature(track.get("title"), artist))

    def item_id_for_sid(self, sid: str) -> str | None:
        entry = self.by_sid.get(sid)
        if not entry or not entry.get("path"):
            return None
        return self._path_to_item.get(Path(entry["path"]).as_posix())

    def attach_local(self, tracks: list[dict], user_headers: dict, user_id: str) -> list[dict]:
        """Fills track["jellyfin"] with the user's Jellyfin item when the song is downloaded."""
        self.refresh()
        wanted = {}
        for t in tracks:
            sid = self.local_sid(t)
            item_id = self.item_id_for_sid(sid) if sid else None
            if item_id:
                wanted.setdefault(item_id, []).append(t)
        if not wanted:
            return tracks
        ids = list(wanted)
        for i in range(0, len(ids), 100):
            r = jf_request("GET", "/Items", headers=user_headers, params={
                "userId": user_id, "ids": ",".join(ids[i:i + 100]), "Fields": ITEM_FIELDS,
            })
            if not r.ok:
                continue
            for item in r.json().get("Items", []):
                for t in wanted.get(item["Id"], []):
                    t["jellyfin"] = item
        return tracks

    def local_tracks_for_artists(self, names: list[str], limit: int, exclude_sigs: set[str]) -> list[str]:
        """Random downloaded songs (spotify ids) by any of these artists."""
        self.refresh()
        pool = []
        for n in names:
            pool += self.by_artist.get(normalize(n), [])
        pool = [sid for sid in dict.fromkeys(pool)
                if song_signature(self.by_sid[sid].get("title"), self.by_sid[sid].get("artist")) not in exclude_sigs]
        random.shuffle(pool)
        return pool[:limit]

    def scan_folder_of(self, path: str):
        """Asks Jellyfin to rescan the closest known folder (album, then artist) of a new file."""
        folders = {}
        try:
            r = jf_request("GET", "/Items", admin=True, params={
                "Recursive": "true", "IncludeItemTypes": "MusicAlbum,Folder", "Fields": "Path", "Limit": 100000})
            folders = {Path(i["Path"]).as_posix(): i["Id"] for i in r.json().get("Items", []) if i.get("Path")}
        except Exception as e:
            print("[library] folder lookup failed:", e)
        album_dir = Path(path).parent
        for folder in (album_dir, album_dir.parent):
            folder_id = folders.get(folder.as_posix())
            if folder_id:
                jf_request("POST", f"/Items/{folder_id}/Refresh", admin=True, params={
                    "Recursive": "true", "MetadataRefreshMode": "Default", "ImageRefreshMode": "Default",
                    "ReplaceAllMetadata": "false", "ReplaceAllImages": "false"})
                return
        # New artist folder: only a library scan will find it.
        try:
            import jellyfin
            jellyfin.refresh_library()
        except Exception as e:
            print("[library] library refresh failed:", e)

    def wait_for_item(self, path: str, timeout: float = 90) -> str | None:
        """After writing a file into the library, waits until Jellyfin has indexed it (with metadata)."""
        norm = Path(path).as_posix()
        start = time.time()
        full_refresh_sent = False
        while time.time() - start < timeout:
            with self._lock:
                try:
                    self._reload_index(force=True)
                except Exception:
                    pass
                item = self._path_to_item.get(norm)
            if item:
                # Indexed: give the metadata probe a moment to fill duration / album.
                for _ in range(20):
                    r = jf_request("GET", f"/Items/{item}", admin=True)
                    if r.ok and r.json().get("RunTimeTicks"):
                        break
                    time.sleep(0.5)
                return item
            if not full_refresh_sent and time.time() - start > 25:
                # The targeted scan didn't catch it: scan the music library.
                try:
                    import jellyfin
                    jellyfin.refresh_library()
                except Exception as e:
                    print("[library] full refresh failed:", e)
                full_refresh_sent = True
            time.sleep(1.5)
        return None


LIBRARY = Library()
