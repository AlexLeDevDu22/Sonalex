"""
config.py – Where the server keeps its data, and which of its modules are on.

Everything comes from backend/.env (see .env.example), with optional overrides in config.ini:

  SONALEX_DATA_DIR      music, state files, logs, temporary files (default /srv/sonalex)
  SONALEX_JELLYFIN_URL  Jellyfin as this machine reaches it (default http://127.0.0.1:8096)
  SONALEX_ONLINE        1 = online catalog: search, stream and save songs that aren't in the library
  SONALEX_SPOTIFY_SYNC  1 = keep the library in sync with a Spotify account (likes, playlists)
"""

import configparser
import os
from pathlib import Path

from dotenv import load_dotenv

BACKEND_DIR = Path(__file__).resolve().parent
load_dotenv(BACKEND_DIR / ".env")


def _env(name: str, default: str) -> str:
    # MUSIQUE_*: the names before the app was called Sonalex.
    return os.getenv(f"SONALEX_{name}") or os.getenv(f"MUSIQUE_{name}") or default


def feature(name: str) -> bool:
    return _env(name, "0").strip().lower() in ("1", "true", "yes", "on")


DATA_DIR = Path(_env("DATA_DIR", "/srv/sonalex"))
JELLYFIN_URL = _env("JELLYFIN_URL", "http://127.0.0.1:8096").rstrip("/")
LOG_DIR = DATA_DIR / "logs"
TEMP_ROOT = DATA_DIR / "temp"
for _d in (LOG_DIR, TEMP_ROOT):
    try:
        _d.mkdir(parents=True, exist_ok=True)
    except OSError:  # not set up yet (setup.sh creates it): only what needs it will fail
        pass
ONLINE = feature("ONLINE")
SPOTIFY_SYNC = feature("SPOTIFY_SYNC")

CONFIG = configparser.ConfigParser()
CONFIG.read_dict({
    "PATHS": {
        "JELLYFIN_PATH": str(DATA_DIR / "Musics"),
        "TRACKS_JSON": str(DATA_DIR / "tracks.json"),
        "PLAYLISTS_JSON": str(DATA_DIR / "playlists.json"),
    },
    # Spotify sync: only keep the songs that are liked or in a synced playlist.
    "PROCESS": {"ONLY_LIKED": "True"},
})
# Absolute: the API, the nightly sync and the utils scripts don't all run from backend/.
CONFIG.read(BACKEND_DIR / "config.ini")
