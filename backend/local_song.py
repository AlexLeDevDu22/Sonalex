"""
local_song.py – CRUD pour les songs téléchargées localement.

Charge le fichier JSON (TRACKS_JSON) au démarrage et expose des fonctions
pour lire, ajouter et supprimer des songs de la collection locale.

Le fichier JSON a le format :
{
  "spotify_id": {
    "title": "...",
    "artist": "...",
    "featured_artists": [...],
    "album_name": "...",
    "cover_url": "...",
    "artist_cover_url": "...",
    "path": "/srv/..."
  }
}
"""

import fcntl
import json
import os
import shutil
import threading
from contextlib import contextmanager
from pathlib import Path

from config import CONFIG
from song import Song

_SONGS_JSON_PATH = CONFIG.get("PATHS", "TRACKS_JSON")

# ---------------------------------------------------------------------------
# Chargement – the API and the nightly sync are two processes writing the same file:
# reload whenever it changed on disk, and write with read-modify-write under a file lock,
# so one process never overwrites the songs the other just added.
# ---------------------------------------------------------------------------

LOCAL_SONGS: list[Song] = []
_loaded_mtime = None
_mem_lock = threading.RLock()


def _mtime():
    try:
        return os.stat(_SONGS_JSON_PATH).st_mtime_ns
    except FileNotFoundError:
        return None


def _read_disk() -> dict:
    try:
        with open(_SONGS_JSON_PATH, "r", encoding="utf8") as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def reload(force: bool = False):
    """Reloads LOCAL_SONGS (in place) if tracks.json changed since the last read."""
    global _loaded_mtime
    with _mem_lock:
        m = _mtime()
        if not force and m == _loaded_mtime and LOCAL_SONGS:
            return
        LOCAL_SONGS[:] = [Song.parse_json(sid, d) for sid, d in _read_disk().items()]
        _loaded_mtime = m


reload(force=True)


@contextmanager
def _file_lock():
    with _mem_lock:
        with open(_SONGS_JSON_PATH + ".lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)


# ---------------------------------------------------------------------------
# Sérialisation
# ---------------------------------------------------------------------------

def _save_json_song():
    """Persiste la liste LOCAL_SONGS dans le fichier JSON (écriture atomique)."""
    global _loaded_mtime
    data = {song.spotify_id: song.export_json() for song in LOCAL_SONGS}
    tmp = _SONGS_JSON_PATH + ".tmp"
    with open(tmp, "w", encoding="utf8") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
    os.replace(tmp, _SONGS_JSON_PATH)
    _loaded_mtime = _mtime()


def _mutate(fn):
    """Locked read-modify-write: reload from disk, apply `fn(LOCAL_SONGS)`, save."""
    with _file_lock():
        reload()
        fn(LOCAL_SONGS)
        _save_json_song()


# ---------------------------------------------------------------------------
# Accesseurs
# ---------------------------------------------------------------------------

def all_songs() -> list[Song]:
    reload()
    return list(LOCAL_SONGS)


def get_song_by_id(spotify_id: str) -> Song | None:
    """Retourne la song locale correspondant à l'ID Spotify, ou None."""
    reload()
    for song in LOCAL_SONGS:
        if song.spotify_id == spotify_id:
            return song
    return None


def get_song_by_path(path: str) -> Song | None:
    """Retourne la song locale correspondant au chemin local, ou None."""
    reload()
    norm = Path(path).as_posix()
    for song in LOCAL_SONGS:
        if song.local_path and Path(song.local_path).as_posix() == norm:
            return song
    return None


def song_already_downloaded(spotify_id: str) -> str | None:
    """
    Retourne le chemin local du fichier MP3 si la song est déjà téléchargée,
    sinon retourne None.
    """
    song = get_song_by_id(spotify_id)
    if song and song.local_path and os.path.exists(song.local_path):
        return song.local_path
    return None


# ---------------------------------------------------------------------------
# Écriture
# ---------------------------------------------------------------------------

def add_song(song: Song):
    """
    Ajoute ou met à jour une song dans la collection locale et persiste.
    Si une song avec le même spotify_id existe déjà, elle est remplacée.
    """
    def apply(songs):
        for i, existing in enumerate(songs):
            if existing.spotify_id == song.spotify_id:
                songs[i] = song
                return
        songs.append(song)
    _mutate(apply)

def _remove_json_song(spotify_id: str):
    """Retire une song de LOCAL_SONGS par son ID et persiste."""
    _mutate(lambda songs: songs.__setitem__(slice(None), [s for s in songs if s.spotify_id != spotify_id]))


def delete_song(song: Song, just_remove_mp3: bool = False):
    """
    Supprime la song : retire le fichier MP3 (et .lrc), et optionnellement
    retire l'entrée du JSON local. Nettoie aussi les dossiers album/artiste
    s'ils deviennent vides.
    """
    if not song or not song.local_path:
        return

    song_path = song.local_path

    # Retirer du JSON local
    if not just_remove_mp3:
        _remove_json_song(song.spotify_id)

    # Supprimer le MP3
    if os.path.exists(song_path):
        os.remove(song_path)
    for ext in (".lrc", ".txt"):
        lyrics_path = str(Path(song_path).with_suffix(ext))
        if os.path.exists(lyrics_path):
            os.remove(lyrics_path)
    print("Song " + song_path.split("/")[-1] + " removed from files")

    if just_remove_mp3:
        return

    # Supprimer le dossier album si vide
    album_path = os.path.dirname(song_path)
    if os.path.exists(album_path):
        if len(list(Path(album_path).glob("*.mp3"))) > 0:
            return
        shutil.rmtree(album_path)
        print("Album folder " + album_path.split("/")[-1] + " removed")

    # Supprimer le dossier artiste si vide
    artist_path = os.path.dirname(album_path)
    if os.path.exists(artist_path):
        if len(os.listdir(artist_path)) > 0:
            return
        os.rmdir(artist_path)
        print("Artist folder " + artist_path.split("/")[-1] + " removed")