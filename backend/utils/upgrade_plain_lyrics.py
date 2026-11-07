"""
upgrade_plain_lyrics.py – Gets synced lyrics for songs that only have plain ones.

Old downloads sometimes wrote plain lyrics (no [mm:ss] timestamps) into a .lrc file: the apps then
show them without following the song. For each such .lrc / .txt, LRCLIB is asked again (several
strategies, utils/lyrics.py); synced lyrics replace the file, otherwise a plain .lrc is renamed
.txt (what it really is). Jellyfin then rescans those songs. Also run every night (maintenance).

    cd backend && .venv/bin/python -m utils.upgrade_plain_lyrics
"""

import re
import time
from pathlib import Path

from config import CONFIG
from utils.fetch_missing_lyrics import tags
from utils.lyrics import find_lyrics

MUSIC = Path(CONFIG.get("PATHS", "JELLYFIN_PATH"))
TIMESTAMP = re.compile(r"^\[\d+:\d+", re.M)


def is_synced(path: Path) -> bool:
    return bool(TIMESTAMP.search(path.read_text(encoding="utf-8", errors="ignore")))


def main():
    candidates = []
    for lyr in list(MUSIC.rglob("*.lrc")) + list(MUSIC.rglob("*.txt")):
        mp3 = lyr.with_suffix(".mp3")
        if mp3.exists() and not (lyr.suffix == ".lrc" and is_synced(lyr)):
            candidates.append((mp3, lyr))
    print(f"{len(candidates)} songs with plain lyrics only")

    changed = []
    for mp3, lyr in candidates:
        title, artist, album, duration = tags(mp3)
        text, synced = find_lyrics(title, artist, album, duration)
        if text and synced:
            mp3.with_suffix(".lrc").write_text(text, encoding="utf-8")
            if lyr.suffix == ".txt":
                lyr.unlink()
            print(f"  ✓ synchronisées : {artist} – {title}")
            changed.append(mp3)
        elif lyr.suffix == ".lrc":
            lyr.rename(lyr.with_suffix(".txt"))
            changed.append(mp3)
        time.sleep(0.3)
    print(f"{len(changed)} fichiers mis à jour")

    if changed:
        import jellyfin
        jellyfin.build_path_index()
        for mp3 in changed:
            item_id = jellyfin.get_item_id_from_path(str(mp3))
            if item_id:
                jellyfin._post(f"{jellyfin.SERVER}/Items/{item_id}/Refresh", raise_for_status=False,
                               params={"MetadataRefreshMode": "Default", "ReplaceAllMetadata": "false"})


if __name__ == "__main__":
    main()
