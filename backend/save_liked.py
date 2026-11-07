import glob
import json
import os
import subprocess

from config import CONFIG
from utils.tag_mp3_metadata import add_metadata_to_mp3
from spotify import get_spotify_liked_tracks, download_online_cover_image
from tools import song_path, cover_path, simplify_tracks

JELLYFIN_PATH = CONFIG.get("PATHS", "JELLYFIN_PATH")

env = os.environ.copy()
env["PATH"] += ":" + os.path.expanduser("~/.deno/bin")


def empty_cache():
    cache = os.path.expanduser("~/.cache/ytmdl")

    for pattern in ("*_new.mp3", "*.part", "*.temp"):
        for file in glob.glob(os.path.join(cache, pattern)):
            os.remove(file)

empty_cache()

def reset_liked_folder():

    spotify_tracks = get_spotify_liked_tracks(all=True)
    spotify_data = simplify_tracks(spotify_tracks)

    if os.path.exists(TRACKS_FILE):
        with open(TRACKS_FILE, "r", encoding="utf8") as f:
            downloaded_tracks = json.load(f)
    else:
        downloaded_tracks = []

    downloaded = {t["id"]: t for t in downloaded_tracks}
    spotify = {t["id"]: t for t in spotify_data}

    #
    # Suppression
    #

    for track_id, song in downloaded.items():

        if track_id in spotify:
            continue

        if os.path.exists(song["path"]):
            os.remove(song["path"])
            print(f"🗑 {song['title']}")

            album_dir = os.path.dirname(song["path"])

            if not any(
                f.endswith(".mp3")
                for f in os.listdir(album_dir)
            ):
                cover = os.path.join(album_dir, "cover.jpg")

                if os.path.exists(cover):
                    os.remove(cover)

                os.rmdir(album_dir)

                artist_dir = os.path.dirname(album_dir)

                if not os.listdir(artist_dir):
                    os.rmdir(artist_dir)

    #
    # Téléchargement
    #

    errors = []

    for i, item in enumerate(spotify_tracks):

        track = item["track"]

        artist = track["artists"][0]["name"]
        album = track["album"]["name"]
        title = track["name"]

        final_path = song_path(artist, album, title)

        if os.path.exists(final_path):
            print(f"✅ {title}")
            continue

        print(f"\n{i+1}/{len(spotify_tracks)}")
        print(f"⬇ {artist} - {title}")

        album_dir = os.path.dirname(final_path)
        os.makedirs(album_dir, exist_ok=True)

        before = set(os.listdir(album_dir))

        try:
            subprocess.run(
                [
                    "ytmdl",
                    title,
                    f"--artist={artist}",
                    "--album",
                    album,
                    "--format=mp3",
                    "--skip-meta",
                    "--ignore-chapters",
                    "--quiet",
                    "-o",
                    album_dir,
                ],
                env=env,
                check=True,
            )

        except subprocess.CalledProcessError:
            errors.append(f"{artist} - {title}")
            continue

        after = set(os.listdir(album_dir))
        created = after - before

        mp3 = None

        for file in created:
            if file.endswith(".mp3"):
                mp3 = file
                break

        if mp3 is None:
            errors.append(f"{artist} - {title}")
            continue

        os.rename(
            os.path.join(album_dir, mp3),
            final_path,
        )

        add_metadata_to_mp3(
            final_path,
            title,
            artist,
            album,
            track["album"]["images"][0]["url"]
            if track["album"]["images"]
            else None,
        )

        cover = cover_path(artist, album)

        if (
            not os.path.exists(cover)
            and track["album"]["images"]
        ):
            download_online_cover_image(
                track["album"]["images"][0]["url"],
                cover,
            )

    with open(TRACKS_FILE, "w", encoding="utf8") as f:
        json.dump(
            spotify_data,
            f,
            indent=4,
            ensure_ascii=False,
        )

    print()
    print("Errors :", len(errors))

    for e in errors:
        print(" -", e)

    print("Done.")


if __name__ == "__main__":
    reset_liked_folder()