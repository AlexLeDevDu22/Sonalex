"""
retag_library.py – Completes the tags of every song already in the library.

Adds what the old downloads didn't write: album artist (TPE2), track / disc number (TRCK, TPOS)
and release date (TDRC), from Spotify (50 songs per request). Title, artists and cover are left
as they are. Also stores those fields in tracks.json, then asks Jellyfin to rescan.

    cd backend && .venv/bin/python -m utils.retag_library [--dry-run]
"""

import os
import sys

from mutagen.id3 import ID3, ID3NoHeaderError, TDRC, TPE2, TPOS, TRCK

import jellyfin
import local_song
from song import Song
from spotify import get_spotify_tracks


def main(dry_run: bool = False):
    songs = [s for s in local_song.all_songs() if s.local_path and os.path.exists(s.local_path)]
    print(f"{len(songs)} songs")
    tracks = {t["id"]: t for t in get_spotify_tracks([s.spotify_id for s in songs])}
    updated = {}
    for s in songs:
        t = tracks.get(s.spotify_id)
        if not t:
            print("  pas trouvé sur Spotify :", s)
            continue
        for k, v in Song.album_fields(t).items():
            setattr(s, k, v)
        if dry_run:
            continue
        try:
            tags = ID3(s.local_path)
        except ID3NoHeaderError:
            tags = ID3()
        tags.setall("TPE2", [TPE2(encoding=3, text=s.album_artist or s.artist)])
        if s.track_number:
            tags.setall("TRCK", [TRCK(encoding=3, text=f"{s.track_number}/{s.track_total}" if s.track_total else str(s.track_number))])
        if s.disc_number:
            tags.setall("TPOS", [TPOS(encoding=3, text=str(s.disc_number))])
        if s.release_date:
            tags.setall("TDRC", [TDRC(encoding=3, text=str(s.release_date)[:10])])
        tags.save(s.local_path)
        updated[s.spotify_id] = s

    print(f"{len(updated)} fichiers retaggés" + (" (dry run)" if dry_run else ""))
    if dry_run or not updated:
        return

    def apply(all_songs):
        for i, song in enumerate(all_songs):
            if song.spotify_id in updated:
                all_songs[i] = updated[song.spotify_id]
    local_song._mutate(apply)

    jellyfin.refresh_library()
    print("Jellyfin : rescan demandé")


if __name__ == "__main__":
    main(dry_run="--dry-run" in sys.argv)
