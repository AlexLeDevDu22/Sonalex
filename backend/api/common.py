"""
common.py – Shared helpers for the Sonalex server (paths, normalization, caches).

The API reuses the existing backend modules (song, local_song, spotify…), which read
chosic_data.json relative to the working directory: we pin it to backend/.
"""

import json
import os
import re
import sys
import threading
import time
import unicodedata
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
os.chdir(BACKEND_DIR)
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from dotenv import load_dotenv  # noqa: E402

load_dotenv(BACKEND_DIR / ".env")

from config import CONFIG, DATA_DIR, JELLYFIN_URL, LOG_DIR, TEMP_ROOT  # noqa: E402,F401

MUSIC_DIR = Path(CONFIG.get("PATHS", "JELLYFIN_PATH"))
TRACKS_JSON = Path(CONFIG.get("PATHS", "TRACKS_JSON"))
TEMP_DIR = Path(os.getenv("SONALEX_TEMP_DIR") or os.getenv("MUSIQUE_TEMP_DIR") or TEMP_ROOT / "stream")
CACHE_DIR = BACKEND_DIR / "api_cache"
LASTFM_API_KEY = os.getenv("LASTFM_API_KEY", "")

TEMP_DIR.mkdir(parents=True, exist_ok=True)
CACHE_DIR.mkdir(parents=True, exist_ok=True)


def normalize(text: str | None) -> str:
    """Lowercase, no accents, no punctuation, single spaces."""
    if not text:
        return ""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c)).lower()
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def base_title(title: str | None) -> str:
    """Title without "(feat. …)", "- Remastered", "[From …]" decorations, normalized."""
    t = title or ""
    t = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", t)
    t = re.sub(r"\s+-\s+.*$", "", t)
    return normalize(t)


def song_signature(title: str | None, artist: str | None) -> str:
    """Key used to recognise the same song across Spotify / Deezer / Last.fm / local files."""
    return f"{base_title(title)}|{normalize(artist).split(' feat')[0]}"


def parse_range(header: str | None, size: int) -> tuple[int, int] | None:
    """(first, last) bytes of an HTTP Range header, clamped to the file; None = not satisfiable.
    No header, or one that makes no sense: the whole file."""
    whole = (0, size - 1)
    if not header or not header.startswith("bytes="):
        return whole
    first, _, last = header[6:].split(",")[0].strip().partition("-")
    try:
        if first:
            start, end = int(first), int(last) if last else size - 1
        elif last:  # suffix range: last N bytes
            start, end = max(size - int(last), 0), size - 1
        else:
            return whole
    except ValueError:
        return whole
    end = min(end, size - 1)
    return (start, end) if start <= end else None


class TTLCache:
    """Small thread-safe in-memory cache."""

    def __init__(self, ttl: float, max_items: int = 2000):
        self.ttl = ttl
        self.max_items = max_items
        self._data: dict = {}
        self._lock = threading.Lock()

    def get(self, key):
        with self._lock:
            hit = self._data.get(key)
            if not hit:
                return None
            if hit[0] < time.time():
                self._data.pop(key, None)
                return None
            return hit[1]

    def set(self, key, value):
        with self._lock:
            if len(self._data) >= self.max_items:
                # Drop the oldest quarter.
                for k in sorted(self._data, key=lambda k: self._data[k][0])[: self.max_items // 4]:
                    self._data.pop(k, None)
            self._data[key] = (time.time() + self.ttl, value)


class JsonStore:
    """A dict persisted to a JSON file (e.g. Deezer → Spotify matches)."""

    def __init__(self, name: str):
        self.path = CACHE_DIR / name
        self._lock = threading.Lock()
        try:
            self._data = json.loads(self.path.read_text(encoding="utf8"))
        except (FileNotFoundError, json.JSONDecodeError):
            self._data = {}

    def get(self, key, default=None):
        with self._lock:
            return self._data.get(key, default)

    def set(self, key, value):
        with self._lock:
            self._data[key] = value
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self._data, ensure_ascii=False), encoding="utf8")
            tmp.replace(self.path)
