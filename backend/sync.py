"""
sync.py – Moteur de synchronisation bidirectionnel Spotify ↔ Jellyfin

Algorithme :
  1. Charger l'état précédent (playlists.json)
  2. Récupérer l'état actuel Jellyfin (via API)
  3. Récupérer l'état actuel Spotify (via API)
  4. Calculer les diffs (par rapport à l'état précédent)
  5. Merger les diffs avec priorité Jellyfin
  6. Appliquer les changements (téléchargements, appels API)
  7. Sauvegarder le nouvel état

Règles de priorité Jellyfin (en cas de conflit) :
  - Track supprimée dans Jellyfin ET présente dans Spotify  → supprimer de Spotify
  - Track supprimée dans Spotify mais toujours dans Jellyfin → re-ajouter à Spotify (Jellyfin gagne)
  - Track ajoutée dans les deux → union (garder les deux)
  - Playlist supprimée dans Jellyfin → plus synchronisée (« untracked », la playlist Spotify est gardée)
  - Playlist supprimée dans Spotify → supprimer de Jellyfin

Les changements faits côté Jellyfin sont normalement déjà poussés en direct par live_sync.py
(API) : ici c'est le filet de sécurité, plus le sens Spotify → Jellyfin (téléchargements).
"""

from pathlib import Path
import os
from dotenv import load_dotenv

from config import CONFIG
import local_song
from song import Song
from downloading import download_song
from jellyfin import (
    get_all_jellyfin_playlists,
    get_jellyfin_playlist_items,
    add_track_to_playlist_by_spotify_id,
    remove_track_from_playlist_by_spotify_id,
    create_jellyfin_playlist,
    delete_jellyfin_playlist,
    build_path_index,
    refresh_library,
    get_music_library_id,
)
from spotify import (
    get_spotify_playlists,
    get_spotify_playlist_tracks,
    get_spotify_liked_tracks,
    add_track_to_spotify_playlist,
    remove_track_from_spotify_playlist
)
from playlists import (
    PLAYLISTS_JSON,
    _save_playlist_file,
    is_track_in_any_playlist,
    create_playlist,
    tracked_playlists,
)

load_dotenv()
SPOTIFY_USER_ID = os.getenv("SPOTIFY_USER_ID")

PLAYLISTS_JSON_PATH = CONFIG.get("PATHS", "PLAYLISTS_JSON")


# ---------------------------------------------------------------------------
# Helpers – lecture de l'état Jellyfin
# ---------------------------------------------------------------------------

def _get_jellyfin_state(previous_state: dict) -> dict:
    """
    Construit un dictionnaire { spotify_id: set(spotify_track_ids) }
    à partir des playlists Jellyfin actuelles.

    On retrouve les spotify_track_ids en croisant le chemin du fichier
    Jellyfin avec tracks.json (qui contient le chemin local de chaque track).
    """
    # Construire un index inversé path → spotify_track_id depuis local_song
    path_to_spotify_id = {}
    for s in local_song.all_songs():
        if s.local_path:
            path_to_spotify_id[Path(s.local_path).as_posix()] = s.spotify_id

    # Construire un index jellyfin_id → spotify_id pour les playlists connues
    jellyfin_id_to_spotify_id = {}
    for sp_id, data in previous_state.items():
        jf_id = data.get("jellyfin_id")
        if jf_id:
            jellyfin_id_to_spotify_id[jf_id] = sp_id

    # Récupérer toutes les playlists Jellyfin
    jellyfin_playlists = get_all_jellyfin_playlists()
    jellyfin_id_to_name = {pl["Id"]: pl["Name"] for pl in jellyfin_playlists}
    # Songs présentes dans Jellyfin : une song absente (rescan, fichier manquant) ne compte pas
    # comme retirée de la playlist.
    import jellyfin
    present_ids = {path_to_spotify_id.get(Path(p).as_posix()) for p in (jellyfin._ITEMS_BY_PATH or {})}

    state = {}
    for jf_id, sp_id in jellyfin_id_to_spotify_id.items():
        if sp_id == "likes":
            continue  # les likes sont gérés séparément dans liked.py
        if jf_id not in jellyfin_id_to_name:
            continue  # supprimée dans Jellyfin
        items = get_jellyfin_playlist_items(jf_id)
        track_ids = set()
        for item in items:
            path = item.get("Path")
            if path:
                norm = Path(path).as_posix()
                spotify_id = path_to_spotify_id.get(norm)
                if spotify_id:
                    track_ids.add(spotify_id)
        track_ids |= {t for t in previous_state.get(sp_id, {}).get("tracks", []) if t not in present_ids}
        state[sp_id] = {
            "jellyfin_id": jf_id,
            "name": jellyfin_id_to_name.get(jf_id, previous_state.get(sp_id, {}).get("name", "")),
            "tracks": track_ids,
        }

    return state


def _get_spotify_state() -> dict:
    """
    Construit un dictionnaire { spotify_playlist_id: set(spotify_track_ids) }
    à partir des playlists Spotify actuelles.
    """
    playlists = get_spotify_playlists()
    state = {}
    for pl in playlists:
        pl_id = pl["id"]
        items = get_spotify_playlist_tracks(pl_id, all=True)
        track_ids = set()
        for item in items:
            track = item.get("track")
            if track and track.get("id"):
                track_ids.add(track["id"])
        state[pl_id] = {
            "name": pl["name"],
            "snapshot_id": pl["snapshot_id"],
            "editable": pl["collaborative"] or pl["owner"]["id"] == SPOTIFY_USER_ID,
            "tracks": track_ids,
        }
    return state


# ---------------------------------------------------------------------------
# Calcul des diffs
# ---------------------------------------------------------------------------

def _compute_diff(previous_tracks: set, current_tracks: set) -> dict:
    """
    Retourne { 'added': set, 'removed': set } entre l'état précédent et l'état actuel.
    """
    return {
        "added": current_tracks - previous_tracks,
        "removed": previous_tracks - current_tracks,
    }


# ---------------------------------------------------------------------------
# Application des changements
# ---------------------------------------------------------------------------

def _ensure_track_downloaded(spotify_track_id: str) -> str | None:
    """
    Télécharge la song si nécessaire. Retourne le chemin local ou None en cas d'échec.
    """
    path = local_song.song_already_downloaded(spotify_track_id)
    if path:
        return path
    from spotify import get_spotify_track_info
    info = get_spotify_track_info(spotify_track_id)
    if not info or not info.get("name"):
        print(f"[Sync] ⚠️  No info for track {spotify_track_id}")
        return None
    song = Song.parse_spotify(info)
    try:
        return download_song(song)
    except Exception as e:
        print(f"[Sync] ❌ Failed to download {spotify_track_id}: {e}")
        return None


def sync_playlists():
    """
    Point d'entrée principal du sync bidirectionnel des playlists.
    Ne gère pas les likes (gérés dans liked.py).
    """
    global PLAYLISTS_JSON

    print("\n=== Sync bidirectionnel des playlists ===")

    # Rafraîchir la bibliothèque Jellyfin avant de lire l'état
    print("[Sync] Rafraîchissement bibliothèque Jellyfin...")
    refresh_library(get_music_library_id())
    build_path_index()

    previous_state = tracked_playlists()

    print("[Sync] Lecture état Jellyfin...")
    jellyfin_state = _get_jellyfin_state(previous_state)

    print("[Sync] Lecture état Spotify...")
    spotify_state = _get_spotify_state()

    if CONFIG.getboolean("PROCESS", "ONLY_LIKED"):
        liked_track_ids = set(PLAYLISTS_JSON.get("likes", {}).get("tracks", []))

    # -----------------------------------------------------------------------
    # Playlists supprimées côté Jellyfin
    # -----------------------------------------------------------------------
    for sp_id, prev in list(previous_state.items()):
        if sp_id not in jellyfin_state:
            print(f"[Sync] Playlist '{prev['name']}' supprimée dans Jellyfin → plus synchronisée (gardée sur Spotify)")
            # Pierre tombale : sans elle, la playlist serait re-créée dans Jellyfin au prochain run.
            PLAYLISTS_JSON[sp_id].update({"untracked": True, "jellyfin_id": None, "tracks": []})
            _save_playlist_file()

    # -----------------------------------------------------------------------
    # Playlists supprimées côté Spotify
    # -----------------------------------------------------------------------
    for sp_id, prev in list(previous_state.items()):
        if sp_id not in spotify_state and sp_id in jellyfin_state:
            print(f"[Sync] Playlist '{prev['name']}' supprimée dans Spotify → suppression de Jellyfin")
            jf_id = prev.get("jellyfin_id")
            if jf_id:
                delete_jellyfin_playlist(jf_id)
            del PLAYLISTS_JSON[sp_id]
            _save_playlist_file()

    # -----------------------------------------------------------------------
    # Nouvelles playlists côté Spotify (pas encore dans le JSON local)
    # -----------------------------------------------------------------------
    for sp_id, sp_data in spotify_state.items():
        if sp_id not in PLAYLISTS_JSON:
            print(f"[Sync] Nouvelle playlist Spotify '{sp_data['name']}' → création dans Jellyfin")

            create_playlist(sp_data["name"], sp_id, sp_data["snapshot_id"], sp_data["editable"])
            # On va traiter les tracks ci-dessous dans la boucle principale

    # -----------------------------------------------------------------------
    # Sync track par track pour chaque playlist connue
    # -----------------------------------------------------------------------
    for sp_id in list(tracked_playlists().keys()):

        prev_data = previous_state.get(sp_id, {})
        prev_tracks = set(prev_data.get("tracks", []))
        jf_data = jellyfin_state.get(sp_id, {})
        jf_tracks = jf_data.get("tracks", set())
        sp_data = spotify_state.get(sp_id, {})
        sp_tracks = sp_data.get("tracks", set())

        jf_diff = _compute_diff(prev_tracks, jf_tracks)
        sp_diff = _compute_diff(prev_tracks, sp_tracks)

        playlist_name = PLAYLISTS_JSON[sp_id]["name"]
        jellyfin_id = PLAYLISTS_JSON[sp_id]["jellyfin_id"]
        is_editable = PLAYLISTS_JSON[sp_id]["editable"]

        if CONFIG.getboolean("PROCESS", "ONLY_LIKED"):
            has_printed_skip_message = False
        if not is_editable:
            has_printed_not_editable_message = False

        print(f"\n[Sync] Playlist '{playlist_name}' ({sp_id})")
        print(f"  Précédent: {len(prev_tracks)} tracks")
        print(f"  Jellyfin:  {len(jf_tracks)} tracks (ajouts={len(jf_diff['added'])}, suppressions={len(jf_diff['removed'])})")
        print(f"  Spotify:   {len(sp_tracks)} tracks (ajouts={len(sp_diff['added'])}, suppressions={len(sp_diff['removed'])})")

        new_tracks = set(prev_tracks)

        # ---- Tracks supprimées dans Jellyfin ----
        for track_id in jf_diff["removed"]:
            print(f"  [Jellyfin→Spotify] ➖ Suppression de {track_id}")
            new_tracks.discard(track_id)
            # Supprimer de Spotify
            if not is_editable:
                if not has_printed_not_editable_message:
                    print(f"  [⚠️] Playlist non éditable → impossible de supprimer de Spotify")
                    has_printed_not_editable_message = True
            else:
                remove_track_from_spotify_playlist(sp_id, track_id)
            # Supprimer le fichier si orphelin
            if not is_track_in_any_playlist(track_id):
                s = local_song.get_song_by_id(track_id)
                if s:
                    local_song.delete_song(s)

        # ---- Tracks supprimées dans Spotify mais toujours dans Jellyfin (Jellyfin gagne) ----
        for track_id in sp_diff["removed"]:
            if not is_editable:
                if not has_printed_not_editable_message:
                    print(f"  [⚠️] Playlist non éditable → impossible de supprimer de Spotify")
                    has_printed_not_editable_message = True
            elif track_id in jf_tracks:
                print(f"  [Conflit Jellyfin gagne] Track {track_id} supprimée de Spotify mais présente dans Jellyfin → re-ajout à Spotify")
                add_track_to_spotify_playlist(sp_id, track_id)
                new_tracks.add(track_id)
            else:
                # Track supprimée des deux côtés
                print(f"  [Spotify→Jellyfin] ➖ Track {track_id} supprimée de Spotify, retrait de Jellyfin aussi")
                new_tracks.discard(track_id)
                if jellyfin_id:
                    remove_track_from_playlist_by_spotify_id(jellyfin_id, track_id)
                if not is_track_in_any_playlist(track_id):
                    s = local_song.get_song_by_id(track_id)
                    if s:
                        local_song.delete_song(s)

        # ---- Tracks ajoutées dans Jellyfin → propager vers Spotify ----
        for track_id in jf_diff["added"]:
            if track_id not in new_tracks:
                if not is_editable:
                    if not has_printed_not_editable_message:
                        print(f"  [⚠️] Playlist non éditable → impossible de supprimer de Spotify")
                        has_printed_not_editable_message = True
                else:
                    print(f"  [Jellyfin→Spotify] ➕ Track {track_id} ajoutée dans Jellyfin → Spotify")
                    add_track_to_spotify_playlist(sp_id, track_id)
                    new_tracks.add(track_id)

        # ---- Tracks ajoutées dans Spotify → télécharger + ajouter dans Jellyfin ----        
        for track_id in sp_diff["added"]:
            if CONFIG.getboolean("PROCESS", "ONLY_LIKED") and track_id not in liked_track_ids:
                if not has_printed_skip_message:
                    print(f"  [ONLY_LIKED] ⏭️ Certaines songs de cette playlist ne sont pas likées → skip")
                    has_printed_skip_message = True
                continue

            print(f"  [Spotify→Jellyfin] ➕ Track {track_id} ajoutée dans Spotify → téléchargement + Jellyfin")
            path = _ensure_track_downloaded(track_id)

            if path and jellyfin_id:
                add_track_to_playlist_by_spotify_id(jellyfin_id, track_id)

            if track_id not in new_tracks:
                new_tracks.add(track_id)

        # ---- Mettre à jour le JSON local ----
        PLAYLISTS_JSON[sp_id]["tracks"] = list(new_tracks)
        if sp_id in spotify_state:
            PLAYLISTS_JSON[sp_id]["snapshot_id"] = spotify_state[sp_id].get("snapshot_id", "")
        _save_playlist_file()
        

    print("\n=== Sync terminé ===")
