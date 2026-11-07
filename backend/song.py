"""
song.py – Modèle de donnée pour une chanson.

La class Song est le modèle central de la codebase.
Elle peut être construite depuis :
  - des données Spotify brutes (parse_spotify)
  - le fichier JSON local (parse_json)

Elle peut être exportée vers :
  - le fichier JSON local (export_json)

Elle peut générer son chemin local (generate_local_path).
"""

import os
import re

from config import CONFIG

JELLYFIN_PATH = CONFIG.get("PATHS", "JELLYFIN_PATH")


def _sanitize_filename(name: str) -> str:
    return re.sub(r'[<>:"/\\|?*]', "-", name).strip()


class Song:
    def __init__(
        self,
        spotify_id: str,
        title: str,
        artist: str,
        featured_artists: list[str],
        album_name: str,
        cover_url: str | None,
        artist_cover_url: str | None,
        local_path: str | None,
        album_artist: str | None = None,
        track_number: int | None = None,
        track_total: int | None = None,
        disc_number: int | None = None,
        release_date: str | None = None,
        duration_ms: int | None = None,
    ):
        self.spotify_id = spotify_id
        self.title = title
        self.artist = artist
        self.featured_artists = featured_artists or []
        self.album_name = album_name
        self.cover_url = cover_url
        self.artist_cover_url = artist_cover_url
        self.local_path = local_path
        # Album info: lets Jellyfin group the album under one artist and order its tracks.
        self.album_artist = album_artist
        self.track_number = track_number
        self.track_total = track_total
        self.disc_number = disc_number
        self.release_date = release_date
        self.duration_ms = duration_ms
        self.cover_path: str | None = None
        self.artist_cover_path: str | None = None

        if self.local_path:
            self.cover_path = os.path.join(os.path.dirname(self.local_path), "cover.jpg")
            self.artist_cover_path = os.path.join(
                os.path.dirname(os.path.dirname(self.local_path)), "artist.jpg"
            )

    # ------------------------------------------------------------------
    # Constructeurs alternatifs
    # ------------------------------------------------------------------

    @classmethod
    def parse_spotify(cls, spotify_data: dict) -> "Song":
        """
        Construit un objet Song depuis les données brutes de l'API Spotify.
        Si la song est déjà téléchargée localement, retourne l'objet local.
        """
        import local_song  # import tardif pour éviter la circularité
        from spotify import get_artist_info

        existing = local_song.get_song_by_id(spotify_data.get("id"))
        if existing:
            return existing

        artist_id = spotify_data.get("artists", [{}])[0].get("id")
        artist_cover_url = None
        if artist_id:
            artist_info = get_artist_info(artist_id)
            images = artist_info.get("images", [])
            artist_cover_url = images[0].get("url") if images else None

        album = spotify_data.get("album") or {}
        images = album.get("images", [])

        return cls(
            spotify_id=spotify_data.get("id"),
            title=spotify_data.get("name"),
            artist=spotify_data.get("artists", [{}])[0].get("name"),
            featured_artists=[a.get("name") for a in spotify_data.get("artists", [])[1:]],
            album_name=spotify_data.get("album", {}).get("name"),
            cover_url=images[0].get("url") if images else None,
            artist_cover_url=artist_cover_url,
            local_path=None,
            **cls.album_fields(spotify_data),
        )

    @staticmethod
    def album_fields(spotify_data: dict) -> dict:
        """Album artist, track/disc number, release date and duration from a Spotify track."""
        album = spotify_data.get("album") or {}
        return {
            "album_artist": ((album.get("artists") or [{}])[0].get("name")
                             or (spotify_data.get("artists") or [{}])[0].get("name")),
            "track_number": spotify_data.get("track_number"),
            "track_total": album.get("total_tracks"),
            "disc_number": spotify_data.get("disc_number"),
            "release_date": album.get("release_date"),
            "duration_ms": spotify_data.get("duration_ms"),
        }

    @classmethod
    def parse_json(cls, spotify_id: str, json_data: dict) -> "Song":
        """Construit un objet Song depuis une entrée du fichier JSON local."""
        return cls(
            spotify_id=spotify_id,
            title=json_data.get("title"),
            artist=json_data.get("artist"),
            featured_artists=json_data.get("featured_artists") or [],
            album_name=json_data.get("album_name"),
            cover_url=json_data.get("cover_url"),
            artist_cover_url=json_data.get("artist_cover_url"),
            local_path=json_data.get("path"),
            album_artist=json_data.get("album_artist"),
            track_number=json_data.get("track_number"),
            track_total=json_data.get("track_total"),
            disc_number=json_data.get("disc_number"),
            release_date=json_data.get("release_date"),
            duration_ms=json_data.get("duration_ms"),
        )

    # ------------------------------------------------------------------
    # Export
    # ------------------------------------------------------------------

    def export_json(self) -> dict:
        """Sérialise la song pour le stockage dans le fichier JSON local."""
        data = {
            "title": self.title,
            "artist": self.artist,
            "featured_artists": self.featured_artists,
            "album_name": self.album_name,
            "cover_url": self.cover_url,
            "artist_cover_url": self.artist_cover_url,
            "path": self.local_path,
        }
        for key in ("album_artist", "track_number", "track_total", "disc_number", "release_date", "duration_ms"):
            if getattr(self, key) is not None:
                data[key] = getattr(self, key)
        return data

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def generate_local_path(self) -> str:
        """
        Calcule et assigne le chemin local du fichier MP3 d'après l'artiste,
        l'album et le titre. Met aussi à jour cover_path et artist_cover_path.
        """
        artist = _sanitize_filename(self.artist) if self.artist else "No Artist"
        album = _sanitize_filename(self.album_name) if self.album_name else "Unknown Album"
        title = _sanitize_filename(self.title) if self.title else "Unknown Title"

        self.local_path = os.path.join(JELLYFIN_PATH, artist, album, f"{title}.mp3")
        self.cover_path = os.path.join(os.path.dirname(self.local_path), "cover.jpg")
        self.artist_cover_path = os.path.join(
            os.path.dirname(os.path.dirname(self.local_path)), "artist.jpg"
        )
        return self.local_path

    def __repr__(self) -> str:
        return f"<Song {self.artist} – {self.title} ({self.spotify_id})>"
