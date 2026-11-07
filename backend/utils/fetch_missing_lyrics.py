"""
fetch_missing_lyrics.py – Adds lyrics to every library song that has none.

For each MP3 in the music folder without a .lrc / .txt next to it, looks the song up on LRCLIB
(utils/lyrics.py: several strategies, synced preferred) and writes the file, then asks Jellyfin
to refresh those songs so the lyrics show up in the apps.

    cd backend && .venv/bin/python -m utils.fetch_missing_lyrics
"""

import time
from pathlib import Path

from mutagen.id3 import ID3
from mutagen.mp3 import MP3

from config import CONFIG
from utils.lyrics import save_lyrics_file

MUSIC = Path(CONFIG.get("PATHS", "JELLYFIN_PATH"))


def tags(path: Path) -> tuple[str, str, str | None, float | None]:
    title, artist, album, duration = path.stem, path.parent.parent.name, path.parent.name, None
    try:
        id3 = ID3(path)
        title = str(id3.get("TIT2") or title)
        artist = str(id3.get("TPE1").text[0]) if id3.get("TPE1") else artist
        album = str(id3.get("TALB") or album)
    except Exception:
        pass
    try:
        duration = MP3(path).info.length
    except Exception:
        pass
    return title, artist, album, duration


def main():
    songs = sorted(p for p in MUSIC.rglob("*.mp3")
                   if not p.with_suffix(".lrc").exists() and not p.with_suffix(".txt").exists())
    print(f"{len(songs)} songs without lyrics")
    added = []
    for i, path in enumerate(songs, 1):
        title, artist, album, duration = tags(path)
        written = save_lyrics_file(str(path), title, artist, album, duration)
        status = Path(written).suffix if written else "—"
        print(f"[{i}/{len(songs)}] {status:5} {artist} – {title}", flush=True)
        if written:
            added.append(path)
        time.sleep(0.3)  # be gentle with LRCLIB

    print(f"\n{len(added)}/{len(songs)} songs got lyrics")
    if not added:
        return
    # Make Jellyfin pick the new lyric files up.
    import jellyfin

    jellyfin.build_path_index()
    for path in added:
        item_id = jellyfin.get_item_id_from_path(str(path))
        if item_id:
            try:
                jellyfin._post(f"{jellyfin.SERVER}/Items/{item_id}/Refresh",
                               params={"MetadataRefreshMode": "Default", "ReplaceAllMetadata": "false"})
            except Exception as e:
                print("refresh failed for", path.name, e)
    print("Jellyfin refresh requested")


if __name__ == "__main__":
    main()
