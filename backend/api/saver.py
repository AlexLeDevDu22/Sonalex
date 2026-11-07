"""
saver.py – Keeps an online song for good.

When a streamed song is liked or added to a playlist from the app, its temporary download is
converted to MP3 and filed into the Jellyfin library exactly like the songs downloaded by the
nightly sync (same Song model, tags, covers, tracks.json entry), so the Spotify ↔ Jellyfin sync
keeps working on it. Then the favorite / playlist action is applied in Jellyfin.
"""

import copy
import os
import shutil
import subprocess
import threading
from pathlib import Path

from . import catalog
from .common import TEMP_DIR
from .library import LIBRARY, jf_request
from .streamer import STREAMER

_save_lock = threading.Lock()


def _reload_local_songs():
    """The nightly sync runs in another process: re-read tracks.json before writing it."""
    import local_song

    local_song.reload(force=True)


def _spotify_id_for(key: str) -> str:
    if key.startswith("sp:"):
        return key[3:]
    meta = catalog.track_meta(key)
    artist = meta["artists"][0]["name"] if meta.get("artists") else ""
    match = catalog.find_spotify_track(meta["title"], artist)
    if not match:
        raise LookupError("Song not found on Spotify: it can’t be added to the library.")
    return match["key"][3:]


def _file_into_library(key: str, sid: str) -> str:
    """Returns the MP3 path in the library, creating it from the streamed file if needed."""
    import local_song
    from spotify import download_online_cover_image
    from song import Song
    from utils.tag_mp3_metadata import add_metadata_to_mp3

    with _save_lock:
        _reload_local_songs()
        existing = local_song.song_already_downloaded(sid)
        if existing:
            return existing

        job = STREAMER.wait_done(key)
        song = Song.parse_spotify(catalog.sp_track(sid))
        song.generate_local_path()
        os.makedirs(os.path.dirname(song.local_path), exist_ok=True)

        # Build the tagged MP3 (+ .lrc) outside the library, then move it in at once:
        # Jellyfin must never see a half-written file (it would index it without metadata).
        staging = copy.copy(song)
        staging.local_path = str(TEMP_DIR / f"save_{sid}.mp3")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(job.path), "-vn",
                        "-codec:a", "libmp3lame", "-b:a", "256k", staging.local_path], check=True, timeout=600)
        add_metadata_to_mp3(staging)
        for ext in (".lrc", ".txt"):  # synced or plain lyrics
            staged = Path(staging.local_path).with_suffix(ext)
            if staged.exists():
                shutil.move(str(staged), str(Path(song.local_path).with_suffix(ext)))
        shutil.move(staging.local_path, song.local_path)

        if song.cover_url and not os.path.exists(song.cover_path):
            download_online_cover_image(song.cover_url, song.cover_path)
        if song.artist_cover_url and not os.path.exists(song.artist_cover_path):
            download_online_cover_image(song.artist_cover_url, song.artist_cover_path)
        local_song.add_song(song)
        print(f"[saver] ✅ {song.artist} - {song.title} → {song.local_path}")
        return song.local_path


def save(key: str, favorite: bool, playlist_id: str | None, user_headers: dict, user_id: str) -> dict:
    sid = _spotify_id_for(key)
    path = _file_into_library(key, sid)

    # Rescan only the album (or artist) folder: seconds instead of a whole-library scan.
    LIBRARY.scan_folder_of(path)
    item_id = LIBRARY.wait_for_item(path)
    if not item_id:
        raise RuntimeError("Jellyfin hasn’t indexed this song yet, try again in a moment.")

    if favorite:
        jf_request("POST", f"/UserFavoriteItems/{item_id}", headers=user_headers, params={"userId": user_id})
    if playlist_id:
        jf_request("POST", f"/Playlists/{playlist_id}/Items", headers=user_headers,
                   params={"ids": item_id, "userId": user_id})

    r = jf_request("GET", f"/Items/{item_id}", headers=user_headers, params={"userId": user_id})
    r.raise_for_status()
    return r.json()
