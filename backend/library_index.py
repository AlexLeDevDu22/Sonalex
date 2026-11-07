"""
library_index.py – Every song on the server, whoever has it: one file, linked into each library.

Each user's tracks.json says which songs are in their library (key: Spotify id, or "dz:<id>" for
Deezer). Before downloading a song for someone, `find_file` looks for it in everybody's: same
Spotify / Deezer id, same ISRC, or same title + artist + duration; `link` then puts it in the new
library as a hard link — no download, no room taken.
"""

import json
import os
import re
import shutil
import threading
import unicodedata
from pathlib import Path

from config import ACCOUNTS_PATH, CONFIG

_lock = threading.Lock()
_tables: dict[str, tuple[float, dict]] = {}  # tracks.json path → (mtime, entries)


def _norm(text: str | None) -> str:
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(c for c in text if not unicodedata.combining(c)).lower()
    text = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", text)
    text = re.sub(r"\s+-\s+.*$", "", text)
    return re.sub(r"[^a-z0-9]+", "", text)


def signature(title: str | None, artist: str | None) -> str:
    return f"{_norm(title)}|{_norm((artist or '').split(',')[0])}"


def _track_files() -> list[str]:
    try:
        accounts = json.loads(ACCOUNTS_PATH.read_text(encoding="utf8")).get("users", {})
    except (OSError, ValueError):
        accounts = {}
    files = [a["tracks"] for a in accounts.values() if a.get("tracks")]
    return files or [CONFIG.get("PATHS", "TRACKS_JSON")]


def _entries() -> list[tuple[str, dict]]:
    """(key, entry) of every song of every library (tracks.json, reread when it changed)."""
    out = []
    with _lock:
        for path in _track_files():
            try:
                mtime = os.stat(path).st_mtime
            except OSError:
                continue
            cached = _tables.get(path)
            if not cached or cached[0] != mtime:
                try:
                    cached = (mtime, json.loads(Path(path).read_text(encoding="utf8")))
                except (OSError, ValueError):
                    continue
                _tables[path] = cached
            out += list(cached[1].items())
    return out


def find_file(key: str | None = None, isrc: str | None = None, title: str | None = None,
              artist: str | None = None, duration_ms: int | None = None, exclude: str | None = None) -> str | None:
    """A file on the server holding this song (None if nobody has it). `exclude`: a path to skip."""
    by_sig = signature(title, artist) if title else None
    fallback = None
    for k, entry in _entries():
        path = entry.get("path")
        if not path or path == exclude:
            continue
        if (key and k == key) or (isrc and entry.get("isrc") == isrc):
            if os.path.exists(path):
                return path
        elif by_sig and fallback is None and signature(entry.get("title"), entry.get("artist")) == by_sig:
            known = entry.get("duration_ms")
            if (not duration_ms or not known or abs(known - duration_ms) <= 3000) and os.path.exists(path):
                fallback = path
    return fallback


def find_key(key: str) -> str | None:
    """File of an online song key ("sp:<id>" / "dz:<id>") if someone on the server has it."""
    if key.startswith("sp:"):
        return find_file(key=key[3:])
    if key.startswith("dz:"):
        return find_file(key=key)
    return None


def link(source: str, destination: str) -> None:
    """`destination` becomes the same file as `source` (its lyrics too), without taking room."""
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    pairs = [(source, destination)] + [(str(Path(source).with_suffix(e)), str(Path(destination).with_suffix(e)))
                                       for e in (".lrc", ".txt")]
    for src, dst in pairs:
        if not os.path.exists(src) or os.path.exists(dst):
            continue
        try:
            os.link(src, dst)
        except OSError:  # another disk: a copy then
            shutil.copy2(src, dst)
    # Album / artist pictures for Jellyfin, if the folder doesn't have them yet.
    for name, src_dir, dst_dir in (("cover.jpg", Path(source).parent, Path(destination).parent),
                                   ("artist.jpg", Path(source).parent.parent, Path(destination).parent.parent)):
        if (src_dir / name).exists() and not (dst_dir / name).exists():
            try:
                os.link(src_dir / name, dst_dir / name)
            except OSError:
                shutil.copy2(src_dir / name, dst_dir / name)
