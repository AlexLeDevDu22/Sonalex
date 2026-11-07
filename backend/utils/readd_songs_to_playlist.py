import jellyfin
import scrapper
import playlists
import local_song

for playlist in scrapper.get_spotify_playlists():
    jellyfin_p_id = playlists.PLAYLISTS_JSON.get(playlist["id"]).get("jellyfin_id")
    for song in scrapper.get_spotify_playlist_tracks(playlist["id"], True):
        if not song["item"]:
            print(f"Song {song} not found in Spotify")
            continue
        print(f"Adding {song['item']['name']} to {playlist['name']}: {jellyfin_p_id}")

        song_jellyfin_id = jellyfin.get_item_id_from_spotify_track(song["item"]["id"])
        if song_jellyfin_id is None:
            print(f"Song {song['item']['name']} by {song['item']['artists'][0]['name']} not found in Jellyfin")
            continue
        jellyfin.add_item_to_jellyfin_playlist(jellyfin_p_id, song_jellyfin_id)