from pathlib import Path
import os, shutil
from local_song import LOCAL_SONGS

def dele(song_path: str):
    if os.path.exists(song_path):
        os.remove(song_path)
    lrc_path = Path(song_path).with_suffix(".lrc")
    if os.path.exists(lrc_path):
        os.remove(lrc_path)
    print("Song " + song_path.split("/")[-1] + " removed from files")

    # Supprimer le dossier album si vide
    album_path = os.path.dirname(song_path)
    if os.path.exists(album_path):
        if len(list(Path(album_path).glob("*.mp3"))) > 0:
            return
        shutil.rmtree(album_path)
        print("Album folder " + album_path.split("/")[-1] + " removed")

    # Supprimer le dossier artiste si vide
    artist_path = os.path.dirname(album_path)
    if os.path.exists(artist_path):
        if len(os.listdir(artist_path)) > 0:
            return
        os.rmdir(artist_path)
        print("Artist folder " + artist_path.split("/")[-1] + " removed")

def parcourir_mp3(dossier):
    dossier = Path(dossier)

    for fichier in dossier.rglob("*.mp3"):
        ok = False
        for song in LOCAL_SONGS:
            if str(fichier) == song.local_path:
                ok = True
                break
        if not ok:
            print("Removing ", fichier)
            input()
            dele(str(fichier))

if __name__ == "__main__":
    # MP3s of the library that tracks.json doesn't know (asks before each deletion).
    from config import CONFIG

    parcourir_mp3(CONFIG.get("PATHS", "JELLYFIN_PATH"))
