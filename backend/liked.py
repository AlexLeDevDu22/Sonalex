"""
liked.py – Gestion bidirectionnelle des titres likés Spotify ↔ favoris Jellyfin

Règles (Jellyfin prioritaire) :
  - Track dans Spotify liked MAIS pas dans favoris Jellyfin (et était dans l'état précédent)
    → Jellyfin gagne : la track est retirée des likes Spotify
  - Track dans favoris Jellyfin MAIS pas dans Spotify liked
    → La track est ajoutée aux likes Spotify
  - Nouvelle track dans Spotify liked → télécharger + marquer favori Jellyfin
"""

from pathlib import Path

from spotify import get_spotify_liked_tracks, add_to_spotify_liked, remove_from_spotify_liked
import local_song
from song import Song
from downloading import download_song
from playlists import remove_playlist_track, add_to_playlist, _save_playlist_file, PLAYLISTS_JSON
from jellyfin import (
    add_to_favorite,
    remove_from_favorite,
    get_jellyfin_favorites,
    build_path_index,
    refresh_library,
    get_music_library_id,
)
import jellyfin
from tools import simplify_tracks
from config import CONFIG


def full_check_likes():
    """
    Synchronisation bidirectionnelle des likes Spotify ↔ favoris Jellyfin.
    """
    print("\n=== Sync likes ===")

    # Récupérer l'état courant depuis les deux sources
    print("[Likes] Lecture des liked tracks Spotify...")
    spotify_tracks = get_spotify_liked_tracks(all=True)
    spotify_data = simplify_tracks(spotify_tracks)
    spotify_ids = {t["id"] for t in spotify_data}

    # État local des likes (les likes = les favoris Jellyfin, pas de playlist ❤️ dans Jellyfin)
    from live_sync import _likes_state
    liked_playlist = _likes_state()

    previous_ids = set(liked_playlist["tracks"])  # état précédent (JSON local)

    # Récupérer les favoris Jellyfin
    print("[Likes] Lecture des favoris Jellyfin...")
    refresh_library(get_music_library_id())
    build_path_index()
    jellyfin_favorites = get_jellyfin_favorites()

    # Construire un index path → spotify_id depuis local_song
    path_to_spotify_id = {}
    for s in local_song.all_songs():
        if s.local_path:
            path_to_spotify_id[Path(s.local_path).as_posix()] = s.spotify_id

    jellyfin_favorite_ids = set()
    for item in jellyfin_favorites:
        path = item.get("Path")
        if path:
            norm = Path(path).as_posix()
            sp_id = path_to_spotify_id.get(norm)
            if sp_id:
                jellyfin_favorite_ids.add(sp_id)

    # Une song absente de Jellyfin (rescan en cours, fichier manquant) n'a pas été « dé-favorisée » :
    # on ne la traite pas comme retirée (sinon unlike Spotify + suppression du fichier).
    present_ids = {path_to_spotify_id.get(Path(p).as_posix()) for p in (jellyfin._ITEMS_BY_PATH or {})}
    jellyfin_favorite_ids |= {t for t in previous_ids if t not in present_ids}

    print(f"[Likes] Précédent: {len(previous_ids)} | Spotify: {len(spotify_ids)} | Jellyfin favs: {len(jellyfin_favorite_ids)}")

    # -----------------------------------------------------------------------
    # Détection des changements
    # -----------------------------------------------------------------------

    jf_removed = previous_ids - jellyfin_favorite_ids   # supprimés de Jellyfin depuis le dernier run
    jf_added   = jellyfin_favorite_ids - previous_ids   # ajoutés dans Jellyfin depuis le dernier run
    sp_removed = previous_ids - spotify_ids             # supprimés de Spotify depuis le dernier run
    sp_added   = spotify_ids - previous_ids             # ajoutés dans Spotify depuis le dernier run

    new_liked_ids = set(previous_ids)

    # -----------------------------------------------------------------------
    # Tracks supprimées des favoris Jellyfin → retirer des likes Spotify (Jellyfin gagne)
    # -----------------------------------------------------------------------
    for track_id in jf_removed:
        print(f"[Likes] [Jellyfin→Spotify] ➖ Track {track_id} retirée des favoris Jellyfin → unlike Spotify")
        remove_from_spotify_liked(track_id)
        remove_playlist_track("likes", track_id)
        new_liked_ids.discard(track_id)

    # -----------------------------------------------------------------------
    # Tracks supprimées de Spotify liked MAIS toujours dans favoris Jellyfin
    # (Jellyfin gagne → re-liker sur Spotify)
    # -----------------------------------------------------------------------
    for track_id in sp_removed:
        if track_id in jellyfin_favorite_ids:
            print(f"[Likes] [Conflit Jellyfin gagne] Track {track_id} unlikée sur Spotify mais encore favorite Jellyfin → re-like Spotify")
            add_to_spotify_liked(track_id)
            new_liked_ids.add(track_id)
        else:
            # Supprimée des deux côtés → on retire du JSON local
            print(f"[Likes] ➖ Track {track_id} retirée des deux côtés")
            remove_playlist_track("likes", track_id)
            new_liked_ids.discard(track_id)

    # -----------------------------------------------------------------------
    # Tracks ajoutées dans les favoris Jellyfin → liker sur Spotify
    # -----------------------------------------------------------------------
    for track_id in jf_added:
        if track_id not in new_liked_ids:
            print(f"[Likes] [Jellyfin→Spotify] ➕ Track {track_id} ajoutée aux favoris Jellyfin → like Spotify")
            add_to_spotify_liked(track_id)
            s = local_song.get_song_by_id(track_id)
            if s and s.local_path:
                add_to_playlist("likes", track_id, s.local_path)
            new_liked_ids.add(track_id)

    # -----------------------------------------------------------------------
    # Nouvelles tracks likées sur Spotify → télécharger + marquer favori Jellyfin
    # -----------------------------------------------------------------------
    errors = []
    spotify_tracks.reverse()  # Pour traiter dans l'ordre chronologique (plus ancienne en premier)
    for item in spotify_tracks:
        track = item["track"]
        if not track:
            continue

        track_id = track["id"]

        new_song = Song.parse_spotify(track)
        if track_id in new_liked_ids:
            print(f"✅ {track['name']} ({track_id})")
            # S'assurer que l'entrée dans local_song est bien présente
            if not local_song.get_song_by_id(track_id):
                print(f"Song {track['name']} not in local songs, adding it...")
                local_song.add_song(new_song)
            continue

        if track_id not in sp_added:
            continue

        title = track["name"]
        artist = track["artists"][0]["name"]
        print(f"[Likes] [Spotify→Jellyfin] ➕ Nouveau like : {artist} - {title}")
        try:
            path = download_song(new_song)
            add_to_playlist("likes", track_id, path)
            add_to_favorite(path)
            new_liked_ids.add(track_id)
        except Exception as e:
            print(f"[Likes] ❌ Erreur pour {title}: {e}")
            errors.append(f"{artist} - {title}")

    # -----------------------------------------------------------------------
    # Sauvegarder le nouvel état
    # -----------------------------------------------------------------------
    PLAYLISTS_JSON["likes"]["tracks"] = list(new_liked_ids)
    _save_playlist_file()

    if errors:
        print(f"\n[Likes] {len(errors)} erreur(s) :")
        for e in errors:
            print(f"  - {e}")

    print("[Likes] ✅ Sync terminé")