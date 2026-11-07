import re
import os

from config import CONFIG

JELLYFIN_PATH = CONFIG.get("PATHS", "JELLYFIN_PATH")


def sanitize_filename(name: str):
    return re.sub(r'[<>:"/\\|?*]', "-", name).strip()

def song_path(artist, album, title):
    artist = sanitize_filename(artist) if artist else "No Artist"
    album = sanitize_filename(album)
    title = sanitize_filename(title)

    return os.path.join(
        JELLYFIN_PATH,
        artist,
        album,
        f"{title}.mp3",
    )

def cover_path(artist, album):
    artist = sanitize_filename(artist)
    album = sanitize_filename(album)

    return os.path.join(
        JELLYFIN_PATH,
        artist,
        album,
        "cover.jpg",
    )


def simplify_tracks(tracks):
    songs = []

    for item in tracks:
        track = item["track"]
        if not track:
            continue

        artist = track["artists"][0]["name"]
        album = track["album"]["name"]
        title = track["name"]

        songs.append(
            {
                "id": track["id"],
                "title": title,
                "artist": artist,
                "album": album,
                "cover": track["album"]["images"][0]["url"]
                if track["album"]["images"]
                else None,
                "path": song_path(artist, album, title),
            }
        )

    return songs