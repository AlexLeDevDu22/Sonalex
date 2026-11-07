"""
redownload_mismatched.py – Re-downloads the songs whose file isn't the right version.

A file much longer / shorter than the Spotify track (clip with an intro, extended mix, remix, live,
another song with the same name…) is downloaded again with the current search (official audio
first, no remix unless the song is one, see downloading.find_sources). The file is replaced only
when a candidate really has the Spotify duration (±3 s); same path, so favorites and playlists
stay. Jellyfin then rescans those songs.

    cd backend && .venv/bin/python -m utils.redownload_mismatched [--dry-run] [--threshold 8]
"""

import argparse
import os
import shutil
import tempfile

from mutagen.mp3 import MP3
from yt_dlp import YoutubeDL

import jellyfin
import local_song
from config import TEMP_ROOT
from downloading import find_sources
from sync_lock import sync_lock
from utils.tag_mp3_metadata import add_metadata_to_mp3

TOLERANCE = 3.0


def file_duration(path: str) -> float | None:
    try:
        return MP3(path).info.length
    except Exception:
        return None


def mismatched(threshold: float):
    out = []
    for s in local_song.all_songs():
        if not s.duration_ms or not s.local_path or not os.path.exists(s.local_path):
            continue
        d = file_duration(s.local_path)
        if d is not None and abs(d - s.duration_ms / 1000) > threshold:
            out.append((s, d))
    return out


def try_source(url: str, staging: str) -> str | None:
    opts = {
        "format": "bestaudio/best", "outtmpl": os.path.join(staging, "song"), "quiet": True,
        "no_warnings": True, "noplaylist": True, "overwrites": True, "retries": 5, "socket_timeout": 30,
        "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "320"}],
    }
    try:
        with YoutubeDL(opts) as ydl:
            ydl.download([url])
    except Exception as e:
        print(f"    indisponible ({str(e)[:80]})")
        return None
    path = os.path.join(staging, "song.mp3")
    return path if os.path.exists(path) else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--threshold", type=float, default=8.0, help="écart (s) à partir duquel on retélécharge")
    args = parser.parse_args()

    with sync_lock():
        songs = mismatched(args.threshold)
        print(f"{len(songs)} songs dont la durée ne correspond pas à Spotify (> {args.threshold:.0f} s)")
        fixed, not_found = [], []
        for song, current in songs:
            target = song.duration_ms / 1000
            print(f"\n{song.artist} - {song.title} : fichier {current:.0f} s, Spotify {target:.0f} s")
            sources = find_sources(song)
            if args.dry_run:
                print(f"  [dry-run] {len(sources)} source(s) à essayer")
                continue
            staging = tempfile.mkdtemp(dir=TEMP_ROOT)
            try:
                done = False
                for url in sources:
                    print(f"  ⬇ {url}")
                    path = try_source(url, staging)
                    if not path:
                        continue
                    d = file_duration(path)
                    if d is None or abs(d - target) > TOLERANCE:
                        print(f"    mauvaise durée ({d and round(d)} s), source suivante")
                        os.remove(path)
                        continue
                    staged = type(song).parse_json(song.spotify_id, song.export_json())
                    staged.local_path = path
                    add_metadata_to_mp3(staged, lyrics=False)
                    shutil.move(path, song.local_path)
                    print(f"  ✅ remplacé ({d:.0f} s)")
                    fixed.append(song.local_path)
                    done = True
                    break
                if not done:
                    not_found.append(song)
                    print("  ❌ aucune version à la bonne durée : fichier gardé")
            finally:
                shutil.rmtree(staging, ignore_errors=True)

        if fixed:
            jellyfin.build_path_index()
            for path in fixed:
                item_id = jellyfin.get_item_id_from_path(path)
                if item_id:
                    jellyfin._post(f"{jellyfin.SERVER}/Items/{item_id}/Refresh", raise_for_status=False,
                                   params={"MetadataRefreshMode": "FullRefresh", "ReplaceAllMetadata": "false"})
        print(f"\n{len(fixed)} remplacé(s), {len(not_found)} sans bonne version :")
        for s in not_found:
            print(f"  - {s.artist} - {s.title}")


if __name__ == "__main__":
    main()
