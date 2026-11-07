"""
user_jobs.py – One job for one user, in a process of its own.

The sync and library modules (live_sync, local_song, playlists, spotify…) read one user's files
at import (config.py, SONALEX_USER): the server runs them here for each user.

    SONALEX_USER=<slug> python user_jobs.py push-playlist <jellyfin playlist id>
    SONALEX_USER=<slug> python user_jobs.py push-favorites <jellyfin item id> …
    SONALEX_USER=<slug> python user_jobs.py reconcile
    SONALEX_USER=<slug> python user_jobs.py save <key> <streamed file or ->

Prints one JSON line with the result (last line of stdout).
"""

import json
import os
import subprocess
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parent
os.chdir(BACKEND)
sys.path.insert(0, str(BACKEND))

from config import USER  # noqa: E402  (the user's paths)


def run(slug: str | None, *args: str, timeout: float = 1800) -> dict:
    """From the server: runs a job for `slug` (None: the server's own single user)."""
    env = {**os.environ}
    if slug:
        env["SONALEX_USER"] = slug
    else:
        env.pop("SONALEX_USER", None)
    p = subprocess.run([sys.executable, str(BACKEND / "user_jobs.py"), *args], env=env, capture_output=True,
                       text=True, timeout=timeout)
    for line in (p.stdout or "").splitlines():
        print(f"[{slug or 'user'}] {line}", flush=True)
    if p.stderr.strip():
        print(f"[{slug or 'user'}] {p.stderr.strip()[-800:]}", flush=True)
    last = (p.stdout or "").strip().splitlines()[-1:] or ["{}"]
    try:
        result = json.loads(last[0])
    except ValueError:
        result = {}
    if p.returncode and "error" not in result:
        result["error"] = (p.stderr or p.stdout or "failed").strip()[-300:]
    return result


def _save(key: str, source: str) -> dict:
    """An online song into this user's library: linked if someone on the server has it, else the
    streamed file converted, tagged and filed like every downloaded song."""
    import copy
    import shutil

    import library_index
    import local_song
    from api import catalog
    from config import TEMP_ROOT
    from song import Song
    from spotify import download_online_cover_image
    from utils.tag_mp3_metadata import add_metadata_to_mp3

    provider = (USER or {}).get("provider", "spotify")
    if key.startswith("dz:") and provider != "spotify":
        song = Song.parse_deezer(catalog.dz_track(key[3:]))
    else:
        if key.startswith("sp:"):
            sid = key[3:]
        else:  # a Deezer song for a Spotify user: its Spotify twin, so it syncs to Spotify
            meta = catalog.track_meta(key)
            match = catalog.find_spotify_track(meta["title"], meta["artists"][0]["name"] if meta.get("artists") else "")
            if not match:
                raise LookupError("Song not found on Spotify: it can’t be added to the library.")
            sid = match["key"][3:]
        existing = local_song.song_already_downloaded(sid)
        if existing:
            return {"path": existing}
        song = Song.parse_spotify(catalog.sp_track(sid))
    existing = local_song.song_already_downloaded(song.spotify_id)
    if existing:
        return {"path": existing}
    song.generate_local_path()
    os.makedirs(os.path.dirname(song.local_path), exist_ok=True)
    shared = library_index.find_file(key=song.spotify_id, isrc=song.isrc, title=song.title, artist=song.artist,
                                     duration_ms=song.duration_ms, exclude=song.local_path)
    if shared:
        library_index.link(shared, song.local_path)
    else:
        if source == "-" or not os.path.exists(source):
            raise RuntimeError("The song isn't downloaded yet.")
        staging = copy.copy(song)
        staging.local_path = str(TEMP_ROOT / f"save_{song.spotify_id.replace(':', '_')}.mp3")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", source, "-vn", "-codec:a", "libmp3lame",
                        "-b:a", "256k", staging.local_path], check=True, timeout=600)
        add_metadata_to_mp3(staging)
        for ext in (".lrc", ".txt"):
            staged = Path(staging.local_path).with_suffix(ext)
            if staged.exists():
                shutil.move(str(staged), str(Path(song.local_path).with_suffix(ext)))
        shutil.move(staging.local_path, song.local_path)
    for url, path in ((song.cover_url, song.cover_path), (song.artist_cover_url, song.artist_cover_path)):
        if url and path and not os.path.exists(path):
            download_online_cover_image(url, path)
    local_song.add_song(song)
    return {"path": song.local_path, "linked": bool(shared)}


def main(job: str, *args: str) -> dict:
    from sync_lock import sync_lock

    if job == "save":
        return _save(*args)
    with sync_lock():
        import live_sync

        if job == "push-playlist":
            return {"result": live_sync.push_playlist(args[0])}
        if job == "push-favorites":
            return {"changes": live_sync.push_favorite_items(list(args))}
        if job == "reconcile":
            live_sync.reconcile()
            return {"ok": True}
    raise SystemExit(f"unknown job {job}")


if __name__ == "__main__":
    try:
        out = main(*sys.argv[1:])
    except Exception as e:
        print(json.dumps({"error": str(e) or repr(e)}))
        sys.exit(1)
    print(json.dumps(out))
