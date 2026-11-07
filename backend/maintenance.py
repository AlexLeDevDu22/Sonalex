"""
maintenance.py – Nightly housekeeping of the library, after the Spotify ↔ Jellyfin sync.

  - repair: liked / playlist songs whose MP3 disappeared are downloaded again;
  - purge: tracks.json entries whose file is gone and that nothing needs anymore are dropped;
  - cleanup: songs unliked / removed from playlists during the day (live sync) are deleted if they
    are still in no playlist and not liked (ONLY_LIKED keeps the library = what you listen to);
  - dedupe: no song twice in a Jellyfin playlist;
  - lyrics: songs without lyrics, or with plain ones only, get another LRCLIB lookup.
"""

import os

import jellyfin
import local_song
import playlists
from config import CONFIG


def _needed_ids() -> set[str]:
    needed = set()
    for key, data in playlists.PLAYLISTS_JSON.items():
        if not data.get("untracked"):
            needed |= set(data.get("tracks", []))
    return needed


def repair_missing_files():
    from sync import _ensure_track_downloaded

    needed = _needed_ids()
    missing = [s for s in local_song.all_songs()
               if s.spotify_id in needed and (not s.local_path or not os.path.exists(s.local_path))]
    for s in missing:
        print(f"[Maintenance] 🔧 Fichier manquant, re-téléchargement : {s.artist} - {s.title}")
        local_song._remove_json_song(s.spotify_id)
        _ensure_track_downloaded(s.spotify_id)
    return len(missing)


def purge_dead_entries():
    needed = _needed_ids()
    dead = [s.spotify_id for s in local_song.all_songs()
            if s.spotify_id not in needed and (not s.local_path or not os.path.exists(s.local_path))]
    if dead:
        dead_set = set(dead)
        local_song._mutate(lambda songs: songs.__setitem__(slice(None), [s for s in songs if s.spotify_id not in dead_set]))
        print(f"[Maintenance] 🧹 {len(dead)} entrée(s) de tracks.json sans fichier retirée(s)")
    return len(dead)


def cleanup_unused_songs():
    """Songs flagged by the live sync (unliked / removed from a playlist during the day)."""
    from live_sync import take_pending_cleanup

    if not CONFIG.getboolean("PROCESS", "ONLY_LIKED"):
        take_pending_cleanup()
        return 0
    needed = _needed_ids()
    removed = 0
    for sid in take_pending_cleanup():
        if sid in needed:
            continue
        song = local_song.get_song_by_id(sid)
        if song:
            print(f"[Maintenance] 🗑 Plus likée ni dans une playlist : {song.artist} - {song.title}")
            local_song.delete_song(song)
            removed += 1
    return removed


def dedupe_playlists():
    total = 0
    for data in playlists.tracked_playlists().values():
        if data.get("jellyfin_id"):
            total += jellyfin.dedupe_jellyfin_playlist(data["jellyfin_id"])
    if total:
        print(f"[Maintenance] {total} doublon(s) retiré(s) des playlists Jellyfin")
    return total


def fetch_missing_lyrics():
    from utils.fetch_missing_lyrics import main
    main()


def analyze_for_mix(budget_s: float = 1800):
    """Mix: analyses the libraries ahead (tempo, beats, key), so transitions are ready at once.
    Every user's songs; a file several users have is analysed once (cached by file, not path)."""
    import time
    from pathlib import Path

    import library_index
    from api.mixinfo import info_for_path

    started, done, seen = time.time(), 0, set()
    for _, entry in library_index._entries():
        path = entry.get("path")
        if time.time() - started > budget_s:
            break
        if not path or not Path(path).exists():
            continue
        st = os.stat(path)
        if (st.st_dev, st.st_ino) in seen:
            continue
        seen.add((st.st_dev, st.st_ino))
        info_for_path(path)  # cached: only new songs cost anything
        done += 1
    print(f"[Mix] {done} songs analysés ou déjà à jour")


def upgrade_plain_lyrics():
    """Songs with only plain lyrics: LRCLIB may have synced ones by now."""
    from utils.upgrade_plain_lyrics import main
    main()
