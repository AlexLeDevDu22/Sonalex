from pathlib import Path
from mutagen.mp3 import MP3
from mutagen import MutagenError


def parcourir_mp3(dossier, callback):
    dossier = Path(dossier)

    for fichier in dossier.rglob("*.mp3"):
        try:
            # Vérifie que le fichier est bien un MP3 lisible
            audio = MP3(fichier)

            # Accès à length force Mutagen à analyser les informations audio
            duree = audio.info.length

            if duree <= 0:
                callback(fichier)
            else :
                print(f"✅ {fichier} -> durée : {duree:.2f} secondes")

        except (MutagenError, OSError, EOFError, ValueError) as e:
            callback(fichier)