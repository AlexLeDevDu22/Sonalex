"""
config.py – Where the server keeps its data, and which of its modules are on.

Everything comes from backend/.env (see .env.example), with optional overrides in config.ini:

  SONALEX_DATA_DIR      music, state files, logs, temporary files (default /srv/sonalex)
  SONALEX_JELLYFIN_URL  Jellyfin as this machine reaches it (default http://127.0.0.1:8096)
  SONALEX_ONLINE        1 = online catalog: search, stream and save songs that aren't in the library
  SONALEX_SPOTIFY_SYNC  1 = keep the libraries in sync with Spotify / Deezer accounts
  JELLYFIN_API_KEY      a Jellyfin API key (Dashboard → API Keys): needed for several users

Several users (accounts.py): each one has a library of their own in Jellyfin, made of hard links to
one copy of each file. The single-user modules (sync, downloads, local_song…) work for one user at a
time: a process sets SONALEX_USER=<slug> and everything below points to that user's files.
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
SIGNUPS = _env("SIGNUPS", "1").strip().lower() in ("1", "true", "yes", "on")
JELLYFIN_API_KEY = os.getenv("JELLYFIN_API_KEY") or _env("JELLYFIN_API_KEY", "")
ACCOUNTS_PATH = DATA_DIR / "accounts.json"
USERS_DIR = DATA_DIR / "users"

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


def _load_user(slug: str) -> dict:
    import json

    try:
        accounts = json.loads(ACCOUNTS_PATH.read_text(encoding="utf8")).get("users", {})
    except (OSError, ValueError):
        accounts = {}
    for account in accounts.values():
        if account.get("slug") == slug:
            return account
    raise SystemExit(f"SONALEX_USER={slug}: no such account in {ACCOUNTS_PATH}")


# The account this process works for (nightly sync, live sync, saving a song…); None = the server.
USER = _load_user(os.environ["SONALEX_USER"]) if os.getenv("SONALEX_USER") else None
if USER:
    CONFIG.set("PATHS", "JELLYFIN_PATH", USER["music"])
    CONFIG.set("PATHS", "TRACKS_JSON", USER["tracks"])
    CONFIG.set("PATHS", "PLAYLISTS_JSON", USER["playlists"])
    # Read by jellyfin.py / spotify.py / playlists.py at import (this module is imported first).
    os.environ["JELLYFIN_USER_ID"] = USER["id"]
    os.environ["SONALEX_LIBRARY_ID"] = USER.get("libraryId") or ""
    os.environ["SONALEX_SPOTIFY_TOKEN"] = USER.get("spotifyToken") or ""
    os.environ["SPOTIFY_USER_ID"] = USER.get("spotifyUser") or os.getenv("SPOTIFY_USER_ID", "")
    if not USER.get("legacy"):
        LOG_DIR = Path(USER["home"]) / "logs"
        LOG_DIR.mkdir(parents=True, exist_ok=True)
