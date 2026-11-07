import local_song
import scrapper

for i in range(len(local_song.LOCAL_SONGS)):
    if not local_song.LOCAL_SONGS[i].cover_url:
        print(local_song.LOCAL_SONGS[i].title)
        cover = scrapper.get_spotify_track_info(local_song.LOCAL_SONGS[i].spotify_id)["album"]["images"][0]["url"]
        local_song.LOCAL_SONGS[i].cover_url = cover

local_song._save_json_song()