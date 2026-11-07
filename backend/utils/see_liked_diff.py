from spotify import get_spotify_liked_tracks
from jellyfin import get_jellyfin_favorites

import unicodedata
import re


# ============================================================
# Normalisation
# ============================================================

def normalize(text: str) -> str:
    """Normalise un texte pour faciliter les comparaisons."""

    if not text:
        return ""

    # Supprime les accents
    text = unicodedata.normalize("NFD", text)
    text = "".join(
        char for char in text
        if unicodedata.category(char) != "Mn"
    )

    # Minuscules
    text = text.lower()

    # Remplace les caractères spéciaux par des espaces
    text = re.sub(r"[^a-z0-9]+", " ", text)

    # Supprime les espaces multiples
    text = re.sub(r"\s+", " ", text)

    return text.strip()


# ============================================================
# Spotify -> ensemble de morceaux
# ============================================================

def spotify_tracks(tracks: list[dict]) -> dict[tuple[str, str], dict]:
    """
    Transforme les morceaux Spotify en dictionnaire :

        (titre_normalisé, artiste_normalisé) -> informations originales
    """

    result = {}

    for item in tracks:
        track = item.get("track")

        if not track:
            continue

        name = track.get("name", "")

        artists = track.get("artists", [])

        # On prend le premier artiste principal
        artist = artists[0].get("name", "") if artists else ""

        key = (
            normalize(name),
            normalize(artist),
        )

        result[key] = {
            "name": name,
            "artist": artist,
        }

    return result


# ============================================================
# Jellyfin -> ensemble de morceaux
# ============================================================

def jellyfin_tracks(tracks: list[dict]) -> dict[tuple[str, str], dict]:
    """
    Transforme les morceaux Jellyfin en dictionnaire.
    """

    result = {}

    for track in tracks:
        name = track.get("Name", "")

        # Jellyfin peut avoir Artists ou AlbumArtist
        artists = track.get("Artists", [])

        if artists:
            artist = artists[0]
        else:
            artist = track.get("AlbumArtist", "")

        key = (
            normalize(name),
            normalize(artist),
        )

        result[key] = {
            "name": name,
            "artist": artist,
            "path": track.get("Path", ""),
        }

    return result


# ============================================================
# Affichage
# ============================================================

def print_section(title: str, items: list[dict], icon: str):
    """Affiche proprement une section de résultats."""

    print()
    print("=" * 75)
    print(f"{icon}  {title} ({len(items)})")
    print("=" * 75)

    if not items:
        print("   Aucun morceau.")
        return

    for i, item in enumerate(items, 1):
        print(f"{i:4}. {item['name']} — {item['artist']}")

        # Affiche le chemin Jellyfin si disponible
        if item.get("path"):
            print(f"       📁 {item['path']}")


# ============================================================
# Comparaison
# ============================================================

def compare_spotify_jellyfin():
    print()
    print("🎵 Synchronisation Spotify ↔ Jellyfin")
    print("-" * 75)

    print("⏳ Récupération des morceaux Spotify...")
    spotify = get_spotify_liked_tracks(True)

    print("⏳ Récupération des favoris Jellyfin...")
    jellyfin = get_jellyfin_favorites()

    print("🔎 Comparaison...")
    
    spotify_dict = spotify_tracks(spotify)
    jellyfin_dict = jellyfin_tracks(jellyfin)

    spotify_keys = set(spotify_dict)
    jellyfin_keys = set(jellyfin_dict)

    # Spotify mais pas Jellyfin
    missing = spotify_keys - jellyfin_keys

    # Jellyfin mais pas Spotify
    extra = jellyfin_keys - spotify_keys

    # Présents dans les deux
    common = spotify_keys & jellyfin_keys

    missing_tracks = [
        spotify_dict[key]
        for key in sorted(
            missing,
            key=lambda x: (x[1], x[0])
        )
    ]

    extra_tracks = [
        jellyfin_dict[key]
        for key in sorted(
            extra,
            key=lambda x: (x[1], x[0])
        )
    ]

    # ========================================================
    # Résumé
    # ========================================================

    print()
    print("╔" + "═" * 73 + "╗")
    print("║" + "📊  RÉSUMÉ".center(73) + "║")
    print("╠" + "═" * 73 + "╣")

    print(
        f"║  Spotify                  : {len(spotify_dict):>6}"
        + " " * 39 + "║"
    )

    print(
        f"║  Jellyfin                 : {len(jellyfin_dict):>6}"
        + " " * 39 + "║"
    )

    print(
        f"║  Présents dans les deux   : {len(common):>6}"
        + " " * 39 + "║"
    )

    print(
        f"║  Manquants dans Jellyfin  : {len(missing):>6}"
        + " " * 39 + "║"
    )

    print(
        f"║  En trop dans Jellyfin    : {len(extra):>6}"
        + " " * 39 + "║"
    )

    print("╚" + "═" * 73 + "╝")

    # ========================================================
    # Détails
    # ========================================================

    print_section(
        "MANQUANTS DANS JELLYFIN",
        missing_tracks,
        "🟢"
    )

    print_section(
        "EN TROP DANS JELLYFIN",
        extra_tracks,
        "🔴"
    )

    print()
    print("=" * 75)
    print("✅ Comparaison terminée.")
    print("=" * 75)


# ============================================================
# Programme principal
# ============================================================

if __name__ == "__main__":
    compare_spotify_jellyfin()