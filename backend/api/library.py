"""
library.py – What is already in a user's library, and on the server.

Each user's songs are listed in their tracks.json (spotify id → title/artist/path) and Jellyfin
knows them by path. This module joins the two so any online result can be swapped for the user's
own copy — or marked as already on the server (a friend has it: it plays at once, saving it is a
link).
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


class Tracks:
    """One user's tracks.json, reread when it changes."""

    def __init__(self, path: Path):
        self.path = path
        self.mtime = 0.0
        self.by_sid: dict[str, dict] = {}
        self.by_sig: dict[str, str] = {}
        self.by_artist: dict[str, list[str]] = {}

    def reload(self):
        try:
            mtime = self.path.stat().st_mtime
        except FileNotFoundError:
            return
        if mtime == self.mtime:
            return
        data = json.loads(self.path.read_text(encoding="utf8"))
        by_sig, by_artist = {}, {}
        for sid, t in data.items():
            by_sig[song_signature(t.get("title"), t.get("artist"))] = sid
            for name in [t.get("artist")] + list(t.get("featured_artists") or []):
                if name:
                    by_artist.setdefault(normalize(name), []).append(sid)
        self.by_sid, self.by_sig, self.by_artist = data, by_sig, by_artist
        self.mtime = mtime


class Library:
    def __init__(self):
        self._lock = threading.Lock()
        self._tables: dict[str, Tracks] = {}
        self._path_to_item: dict[str, str] = {}
        self._index_time = 0.0

    # -- tracks.json -------------------------------------------------------

    def tracks(self, user_id: str | None) -> Tracks:
        """The tracks of a user (their account's tracks.json; the server's own without accounts)."""
        import accounts

        account = accounts.user(user_id) if user_id else None
        path = Path(account["tracks"]) if account else TRACKS_JSON
        with self._lock:
            table = self._tables.setdefault(str(path), Tracks(path))
            table.reload()
        return table

    # Single user (and older callers): the server's own library.
    @property
    def by_sid(self) -> dict:
        return self.tracks(None).by_sid

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
            try:
                self._reload_index(force=force_index)
            except Exception as e:  # Jellyfin briefly unavailable: keep the old index
                print("[library] index refresh failed:", e)

    # -- Lookups ------------------------------------------------------------

    @staticmethod
    def local_sid(table: Tracks, track: dict) -> str | None:
        key = track.get("key", "")
        for candidate in (key[3:] if key.startswith("sp:") else None, key if key.startswith("dz:") else None):
            if candidate and candidate in table.by_sid:
                return candidate
        artist = track["artists"][0]["name"] if track.get("artists") else ""
        return table.by_sig.get(song_signature(track.get("title"), artist))

    def item_id_for_sid(self, table: Tracks, sid: str) -> str | None:
        entry = table.by_sid.get(sid)
        if not entry or not entry.get("path"):
            return None
        return self._path_to_item.get(Path(entry["path"]).as_posix())

    def attach_local(self, tracks: list[dict], user_headers: dict, user_id: str) -> list[dict]:
        """Fills track["jellyfin"] with the user's Jellyfin item when the song is in their library,
        and track["onServer"] when a friend has it (it plays at once, saving it is instant)."""
        import library_index

        self.refresh()
        table = self.tracks(user_id)
        wanted = {}
        for t in tracks:
            sid = self.local_sid(table, t)
            item_id = self.item_id_for_sid(table, sid) if sid else None
            if item_id:
                wanted.setdefault(item_id, []).append(t)
            elif t.get("key") and library_index.find_key(t["key"]):
                t["onServer"] = True
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

    def local_tracks_for_artists(self, names: list[str], limit: int, exclude_sigs: set[str],
                                 user_id: str | None = None) -> list[tuple[str, dict]]:
        """Random songs of the user's library by any of these artists: (key, tracks.json entry)."""
        table = self.tracks(user_id)
        pool = []
        for n in names:
            pool += table.by_artist.get(normalize(n), [])
        pool = [sid for sid in dict.fromkeys(pool)
                if song_signature(table.by_sid[sid].get("title"), table.by_sid[sid].get("artist")) not in exclude_sigs]
        random.shuffle(pool)
        return [(sid, table.by_sid[sid]) for sid in pool[:limit]]

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
        # New artist folder: only a scan of its library will find it.
        self.refresh_library_of(path)

    @staticmethod
    def refresh_library_of(path: str):
        """Rescans the library (of whichever user) the file is in."""
        try:
            libs = jf_request("GET", "/Library/VirtualFolders", admin=True).json()
            target = Path(path).as_posix()
            lib = next((lib for lib in libs for loc in lib.get("Locations") or []
                        if target.startswith(Path(loc).as_posix().rstrip("/") + "/")), None)
            if lib:
                jf_request("POST", f"/Items/{lib['ItemId']}/Refresh", admin=True, params={
                    "Recursive": "true", "ImageRefreshMode": "Default", "MetadataRefreshMode": "Default",
                    "ReplaceAllImages": "false", "ReplaceAllMetadata": "false"})
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
                # The targeted scan didn't catch it: scan the whole library it's in.
                self.refresh_library_of(path)
                full_refresh_sent = True
            time.sleep(1.5)
        return None


LIBRARY = Library()
