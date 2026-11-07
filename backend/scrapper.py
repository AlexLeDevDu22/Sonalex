"""Legacy name: everything Spotify now lives in spotify.py (one token, retries, pagination).
Kept so old imports (`import scrapper`, `from scrapper import …`) keep working."""

from spotify import (  # noqa: F401
    SPOTIFY_USER_ID,
    chosic_data,
    download_online_cover_image,
    get_artist_info,
    get_spotify_liked_tracks,
    get_spotify_playlist_info,
    get_spotify_playlist_tracks,
    get_spotify_playlists,
    get_spotify_track_info,
    refresh_spotify_token,
)
