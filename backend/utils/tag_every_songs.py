import json, os

from config import CONFIG
from utils.tag_mp3_metadata import add_metadata_to_mp3, has_metadata
from downloading import download_song
from song import Song

FORCE = False
TRACKS_JSON = CONFIG.get('PATHS', 'TRACKS_JSON')

with open(TRACKS_JSON, "r", encoding="utf-8") as f:
    downloaded_tracks = json.load(f)

for track_id, track in downloaded_tracks.items():
    title = track["title"]
    artist = track["artist"]
    f_artist = track["featured_artists"]
    album = track["album_name"]
    cover = track["cover_url"]
    path = track["path"]

    if not os.path.exists(track.get('path')):
        download_song(track_id, title, artist, f_artist, album, cover)
    if not FORCE and has_metadata(track["path"]):
        print(f"Skipping {track['title']} - {track['artist']} (metadata already present)")
        continue
    print(f"Adding for {track['title']} - {track['artist']}")
    add_metadata_to_mp3(Song.parse_json(track_id, track))
