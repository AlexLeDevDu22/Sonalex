from mutagen.id3 import ID3, TIT2, TPE1, TPE2, TALB, TRCK, TPOS, TDRC, APIC, ID3NoHeaderError
import requests
import os
from pathlib import Path

def extract_cover(mp3_path, output_path="cover.jpg"):
    audio = ID3(mp3_path)

    # Cherche la première image APIC
    for key in audio.keys():
        if key.startswith("APIC"):
            cover = audio[key]

            with open(output_path, "wb") as img:
                img.write(cover.data)

            return output_path

    return None


def has_metadata(mp3_path):
    """
    Retourne True si le fichier possède déjà les principaux tags
    (titre, artiste, album et cover).
    """
    try:
        audio = ID3(mp3_path)
    except ID3NoHeaderError:
        return False
    has_title = "TIT2" in audio
    has_artist = "TPE1" in audio
    has_album = "TALB" in audio
    has_cover = "APIC:" in audio or any(
        key.startswith("APIC") for key in audio.keys()
    )
    return has_title and has_artist and has_album and has_cover

def download_online_cover_image(online_cover_image_path, temp_file="temp_cover.jpg"):
    """
    Télécharge l'image de couverture depuis l'URL fournie et la sauvegarde dans un fichier temporaire.
    """
    response = requests.get(online_cover_image_path, timeout=20)
    with open(temp_file, "wb") as f:
        f.write(response.content)
    return temp_file


def add_metadata_to_mp3(song, lyrics: bool = True):
    """
    Écrit les tags ID3 dans le MP3 de la song : titre, artistes, album, artiste de l'album,
    n° de piste / disque, année et cover. Puis télécharge les paroles (.lrc / .txt) si absentes.

    Accepte un objet Song (depuis song.py).
    """
    file_path = song.local_path
    audio = ID3()

    audio.add(TIT2(encoding=3, text=song.title or ""))
    audio.add(TPE1(encoding=3, text=[a for a in [song.artist] + (song.featured_artists or []) if a]))
    audio.add(TALB(encoding=3, text=song.album_name or ""))
    # Album artist: without it Jellyfin splits an album with featurings into several albums.
    album_artist = getattr(song, "album_artist", None) or song.artist
    if album_artist:
        audio.add(TPE2(encoding=3, text=album_artist))
    track, total = getattr(song, "track_number", None), getattr(song, "track_total", None)
    if track:
        audio.add(TRCK(encoding=3, text=f"{track}/{total}" if total else str(track)))
    if getattr(song, "disc_number", None):
        audio.add(TPOS(encoding=3, text=str(song.disc_number)))
    if getattr(song, "release_date", None):
        audio.add(TDRC(encoding=3, text=str(song.release_date)[:10]))

    # Cover in memory (no shared temp file: the API and the nightly sync can tag at the same time).
    if song.cover_url:
        try:
            r = requests.get(song.cover_url, timeout=20)
            if r.ok and r.content:
                audio.add(APIC(encoding=3, mime=r.headers.get("Content-Type", "image/jpeg").split(";")[0],
                               type=3, desc="", data=r.content))
        except requests.RequestException:
            pass

    audio.save(file_path)

    if lyrics:
        p = Path(file_path)
        if not p.with_suffix(".lrc").exists() and not p.with_suffix(".txt").exists():
            download_lrc(file_path, song.title, song.artist, song.album_name)


def download_lrc(mp3_path, title, artist, album=None):
    """
    Télécharge les paroles depuis LRCLIB et les enregistre à côté du MP3 :
    .lrc si synchronisées, sinon .txt (Jellyfin lit les deux). Plusieurs recherches sont
    tentées (durée, titre nettoyé, recherche floue) : voir utils/lyrics.py.

    Retourne True si un fichier de paroles a été créé.
    """
    try:
        from mutagen.mp3 import MP3
        from utils.lyrics import save_lyrics_file

        try:
            duration = MP3(mp3_path).info.length
        except Exception:
            duration = None
        path = save_lyrics_file(mp3_path, title, artist, album, duration=duration)
        if path:
            print("Lyrics added to", title)
        return bool(path)
    except Exception:
        return False
