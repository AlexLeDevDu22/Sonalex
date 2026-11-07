import playlists
import scrapper
from song import Song
from spotify import remove_track_from_spotify_playlist, add_track_to_spotify_playlist

import os
from dotenv import load_dotenv

load_dotenv()
SPOTIFY_USER_ID = os.getenv("SPOTIFY_USER_ID")

for p_id, p in playlists.PLAYLISTS_JSON.items():
    if p_id == "likes" or not p["editable"]:
        continue
    tracks = scrapper.get_spotify_playlist_tracks(p_id, True)

    already_added = list()

    for t in tracks:
        s = Song.parse_spotify(t["item"])
        if s.spotify_id in already_added:
            continue

        print(s.title, s.artist)
        remove_track_from_spotify_playlist(p_id, s.spotify_id)
        add_track_to_spotify_playlist(p_id, s.spotify_id)

        already_added.append(s.spotify_id)

        


playlists._save_playlist_file()