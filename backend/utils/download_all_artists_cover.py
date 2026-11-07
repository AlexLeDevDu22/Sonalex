import os

import local_song as local_songs
from utils.tag_mp3_metadata import download_online_cover_image
from scrapper import get_artist_info, get_spotify_track_info

artist_cover = {}

for i in range(len(local_songs.LOCAL_SONGS)):

    if not artist_cover.get(local_songs.LOCAL_SONGS[i].artist):
        if local_songs.LOCAL_SONGS[i].artist_cover_url:
            artist_cover[local_songs.LOCAL_SONGS[i].artist] = local_songs.LOCAL_SONGS[i].artist_cover_url
        else:
            ar_id = get_spotify_track_info(local_songs.LOCAL_SONGS[i].spotify_id).get("artists", [{}])[0].get("id")
            artist_cover[local_songs.LOCAL_SONGS[i].artist] = get_artist_info(ar_id).get("images", [{}])[0].get("url")
    if not local_songs.LOCAL_SONGS[i].artist_cover_url:
        local_songs.LOCAL_SONGS[i].artist_cover_url = artist_cover[local_songs.LOCAL_SONGS[i].artist]
    print(artist_cover[local_songs.LOCAL_SONGS[i].artist])
    if os.path.exists(local_songs.LOCAL_SONGS[i].artist_cover_path):
        continue
    print(f"Downloading cover for {local_songs.LOCAL_SONGS[i].artist}...")
    if not os.path.exists(local_songs.LOCAL_SONGS[i].artist_cover_path):
        download_online_cover_image(
            local_songs.LOCAL_SONGS[i].artist_cover_url,
            local_songs.LOCAL_SONGS[i].artist_cover_path,
        )

local_songs._save_json_song()