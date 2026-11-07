"""
spotify_refreshing.py – Rattrapage depuis Spotify : Spotify prioritaire (à lancer à la main)

L'inverse de full_refreshing.py pour les conflits : après une période passée sur Spotify, Jellyfin
est remis à l'image de Spotify.
  1. Likes : chaque titre liké sur Spotify est téléchargé (si besoin) et mis en favori dans
     Jellyfin ; un favori Jellyfin qui n'est plus liké sur Spotify est retiré des favoris.
  2. Playlists : le contenu de chaque playlist Jellyfin devient celui de Spotify (ajouts et
     retraits), le nom suit ; une playlist suivie dans Spotify mais absente de Jellyfin est créée,
     une playlist qui n'existe plus sur Spotify est supprimée de Jellyfin.
  3. Ménage : comme la nuit (fichiers manquants, songs plus utilisées, doublons, paroles).

Ce que le script ne touche pas :
  - les playlists supprimées volontairement dans Jellyfin (« untracked ») : elles restent
    supprimées, sauf avec --revive-untracked ;
  - les playlists créées dans Jellyfin et jamais synchronisées, et les morceaux d'une playlist
    qui ne viennent pas de Spotify (fichiers ajoutés à la main) ;
  - Spotify : rien n'y est modifié.
ONLY_LIKED (config.ini) reste respecté : dans les playlists, seuls les titres likés sont gardés.

    cd backend
    .venv/bin/python spotify_refreshing.py --dry-run   # affiche ce qui serait fait, ne change rien
    .venv/bin/python spotify_refreshing.py             # applique

Options : --dry-run, --revive-untracked, --keep-files (ne supprime aucun fichier au ménage).
Même verrou que la synchro de nuit et la synchro en direct de l'API (un seul sync à la fois).
Journal : <données>/logs/sync-AAAA-MM-JJ.log.
"""

import argparse
import sys
import time
from pathlib import Path

from full_refreshing import _phase, _setup_logging  # noqa: E402 (also chdir + sys.path to backend/)

DRY = False
STATS: dict[str, int] = {}
LIKED: set[str] = set()  # Spotify likes now in the library (filled by the likes phase)


def _count(key: str, n: int = 1):
    STATS[key] = STATS.get(key, 0) + n


def act(description: str, fn=None):
    """Runs `fn` (unless --dry-run) and logs what is done."""
    print(("  [dry-run] " if DRY else "  ") + description)
    if not DRY and fn is not None:
        return fn()
    return None


def _track_of(entry: dict) -> dict | None:
    """A playlist / likes entry → the track object (Spotify now sends it as "item" and "track")."""
    track = entry.get("track") or entry.get("item")
    if track and track.get("id") and track.get("type", "track") == "track":
        return track
    return None


# ---------------------------------------------------------------------------
# Likes
# ---------------------------------------------------------------------------

def sync_likes_from_spotify() -> list[str]:
    import jellyfin
    import live_sync
    import local_song
    import playlists
    from downloading import download_song
    from song import Song
    from spotify import get_spotify_liked_tracks

    entries = get_spotify_liked_tracks(all=True)
    entries.reverse()  # oldest first: downloads keep the order of your likes
    tracks = [t for t in map(_track_of, entries) if t]
    spotify_ids = [t["id"] for t in tracks]
    print(f"[Likes] Spotify : {len(spotify_ids)} titres likés")

    items = live_sync._library_items()
    path_to_sid = live_sync._path_index()
    fav_by_sid, path_by_sid = {}, {}
    for item in items:
        sid = path_to_sid.get(Path(item.get("Path") or "").as_posix())
        if sid:
            fav_by_sid[sid] = bool((item.get("UserData") or {}).get("IsFavorite"))
            path_by_sid[sid] = item["Path"]

    # 1. Download what's missing (oldest like first), 2. one library scan, 3. favorites.
    labels = {t["id"]: (f"{t['artists'][0]['name']} - {t['name']}" if t.get("artists") else t.get("name")) for t in tracks}
    in_library: list[str] = []
    downloaded_now = 0
    for track in tracks:
        sid = track["id"]
        if local_song.song_already_downloaded(sid):
            in_library.append(sid)
            continue
        _count("téléchargés")
        if DRY:
            act(f"⬇ télécharger : {labels[sid]}")
            in_library.append(sid)
            continue
        try:
            print(f"  ⬇ {labels[sid]}")
            download_song(Song.parse_spotify(track))
            in_library.append(sid)
            downloaded_now += 1
        except Exception as e:
            print(f"  ❌ téléchargement impossible : {labels[sid]} ({e})")
            _count("erreurs")

    if downloaded_now:
        jellyfin.refresh_library()
        time.sleep(30)  # let Jellyfin index the new files before favoriting them
        jellyfin.build_path_index()

    liked_ok: list[str] = []
    for sid in in_library:
        if not fav_by_sid.get(sid):
            _count("favoris ajoutés")
            if DRY:
                act(f"❤️ favori Jellyfin : {labels[sid]}")
            else:
                path = local_song.song_already_downloaded(sid)
                try:
                    act(f"❤️ favori Jellyfin : {labels[sid]}", lambda p=path: jellyfin.add_to_favorite(p))
                except Exception as e:
                    print(f"  ❌ favori impossible : {labels[sid]} ({e})")
                    _count("erreurs")
                    continue
        liked_ok.append(sid)
    LIKED.update(liked_ok)

    spotify_set = set(spotify_ids)
    unliked = [sid for sid, fav in fav_by_sid.items() if fav and sid not in spotify_set]
    for sid in unliked:
        song = local_song.get_song_by_id(sid)
        _count("favoris retirés")
        act(f"💔 plus liké sur Spotify → retiré des favoris : {song.artist + ' - ' + song.title if song else sid}",
            lambda p=path_by_sid[sid]: jellyfin.remove_from_favorite(p))

    if not DRY:
        likes = live_sync._likes_state()
        likes["tracks"] = liked_ok
        playlists._save_playlist_file()
        live_sync._queue_cleanup(unliked)  # deleted at the cleanup phase if in no playlist either
    return liked_ok


# ---------------------------------------------------------------------------
# Playlists
# ---------------------------------------------------------------------------

def _rename_jellyfin_playlist(jf_id: str, name: str):
    import jellyfin

    item = jellyfin._get(f"{jellyfin.SERVER}/Users/{jellyfin.USER_ID}/Items/{jf_id}").json()
    jellyfin._post(f"{jellyfin.SERVER}/Items/{jf_id}", json={**item, "Name": name})


def sync_playlists_from_spotify(revive_untracked: bool):
    import jellyfin
    import live_sync
    import local_song
    import playlists
    from config import CONFIG
    from spotify import SPOTIFY_USER_ID, get_spotify_playlist_tracks, get_spotify_playlists
    from sync import _ensure_track_downloaded

    only_liked = CONFIG.getboolean("PROCESS", "ONLY_LIKED")
    playlists.reload_state()
    state = playlists.PLAYLISTS_JSON
    liked = LIKED or set(state.get("likes", {}).get("tracks", []))

    sp_playlists = {p["id"]: p for p in get_spotify_playlists()}
    if not sp_playlists:
        raise RuntimeError("Spotify ne renvoie aucune playlist : on ne touche à rien")
    jf_ids = {p["Id"] for p in jellyfin.get_all_jellyfin_playlists()}
    jellyfin.build_path_index()
    path_to_sid = live_sync._path_index()
    removed_overall: set[str] = set()

    for sp_id, pl in sp_playlists.items():
        name = pl["name"]
        editable = pl.get("collaborative") or (pl.get("owner") or {}).get("id") == SPOTIFY_USER_ID
        data = state.get(sp_id)
        if data and data.get("untracked") and not revive_untracked:
            continue
        print(f"\n[Playlist] {name}")

        # The Jellyfin side: create it if missing (new on Spotify, or deleted in Jellyfin).
        jf_id = data.get("jellyfin_id") if data else None
        if not jf_id or jf_id not in jf_ids:
            _count("playlists créées")
            jf_id = act(f"➕ création dans Jellyfin : {name}", lambda n=name: jellyfin.create_jellyfin_playlist(n))
            if not DRY:
                state[sp_id] = data = {"tracks": [], "name": name, "id": sp_id, "jellyfin_id": jf_id,
                                       "editable": bool(editable), "snapshot_id": pl.get("snapshot_id", "")}
                playlists._save_playlist_file()
        elif data.get("name") != name:
            _count("playlists renommées")
            act(f"✏️ renommée « {data.get('name')} » → « {name} »", lambda: _rename_jellyfin_playlist(jf_id, name))

        # What Spotify has (in order, no duplicates), ONLY_LIKED applied.
        wanted, seen = [], set()
        for entry in get_spotify_playlist_tracks(sp_id, all=True):
            track = _track_of(entry)
            if not track or track["id"] in seen:
                continue
            seen.add(track["id"])
            if only_liked and track["id"] not in liked:
                continue
            wanted.append(track["id"])
        wanted_set = set(wanted)

        # What Jellyfin has (only songs that come from Spotify; files added by hand are left alone).
        current: dict[str, str] = {}  # spotify id → Jellyfin item id
        if jf_id and jf_id in jf_ids:
            for item in jellyfin.get_jellyfin_playlist_items(jf_id):
                sid = path_to_sid.get(Path(item.get("Path") or "").as_posix())
                if sid:
                    current[sid] = item["Id"]

        for sid, item_id in current.items():
            if sid not in wanted_set:
                song = local_song.get_song_by_id(sid)
                _count("retraits de playlist")
                removed_overall.add(sid)
                act(f"➖ {song.artist + ' - ' + song.title if song else sid}",
                    lambda i=item_id: jellyfin.remove_item_from_jellyfin_playlist(jf_id, i))

        kept = [sid for sid in wanted if sid in current]
        for sid in wanted:
            if sid in current:
                continue
            song = local_song.get_song_by_id(sid)
            _count("ajouts de playlist")
            if DRY:
                act(f"➕ {song.artist + ' - ' + song.title if song else sid}"
                    + ("" if local_song.song_already_downloaded(sid) else " (à télécharger)"))
                continue
            if not _ensure_track_downloaded(sid):
                _count("erreurs")
                continue
            if act(f"➕ {song.artist + ' - ' + song.title if song else sid}",
                   lambda s=sid: jellyfin.add_track_to_playlist_by_spotify_id(jf_id, s)):
                kept.append(sid)

        if not DRY:
            data.update({"tracks": kept, "name": name, "jellyfin_id": jf_id, "editable": bool(editable),
                         "snapshot_id": pl.get("snapshot_id", "")})
            data.pop("untracked", None)
            playlists._save_playlist_file()

    # Playlists we synced that no longer exist on Spotify (deleted / unfollowed): gone from Jellyfin too.
    gone = [k for k in playlists.tracked_playlists() if k not in sp_playlists]
    if len(gone) > max(3, len(playlists.tracked_playlists()) // 3):
        print(f"\n⚠️ {len(gone)} playlists absentes de Spotify d'un coup : réponse Spotify suspecte, aucune suppression")
        gone = []
    for sp_id in gone:
        data = state[sp_id]
        print(f"\n[Playlist] {data.get('name')} n'existe plus sur Spotify")
        _count("playlists supprimées")
        removed_overall |= set(data.get("tracks", []))
        if data.get("jellyfin_id") in jf_ids:
            act(f"🗑 suppression dans Jellyfin : {data.get('name')}",
                lambda j=data["jellyfin_id"]: jellyfin.delete_jellyfin_playlist(j))
        if not DRY:
            del state[sp_id]
            playlists._save_playlist_file()

    if not DRY:
        live_sync._queue_cleanup(removed_overall)


# ---------------------------------------------------------------------------

def main():
    global DRY
    parser = argparse.ArgumentParser(description="Remet Jellyfin à l'image de Spotify (Spotify prioritaire).")
    parser.add_argument("--dry-run", action="store_true", help="affiche ce qui serait fait, ne change rien")
    parser.add_argument("--revive-untracked", action="store_true",
                        help="recrée aussi les playlists supprimées volontairement dans Jellyfin")
    parser.add_argument("--keep-files", action="store_true", help="ne supprime aucun fichier au ménage")
    args = parser.parse_args()
    DRY = args.dry_run

    _setup_logging()
    print("=== Rattrapage depuis Spotify (Spotify prioritaire)" + (" — DRY RUN, rien n'est modifié" if DRY else "") + " ===")
    from sync_lock import sync_lock

    with sync_lock():  # waits for the nightly / live sync; the live sync waits for us
        import jellyfin
        import maintenance
        import playlists

        playlists.reload_state()
        if not DRY:
            jellyfin.refresh_library()
            time.sleep(20)
        jellyfin.build_path_index()

        results = {
            "Likes": _phase("Likes ❤️ (Spotify → Jellyfin)", sync_likes_from_spotify),
            "Playlists": _phase("Playlists (Spotify → Jellyfin)",
                                lambda: sync_playlists_from_spotify(args.revive_untracked)),
        }
        if not DRY:
            playlists.reload_state()
            results["Fichiers manquants"] = _phase("Fichiers manquants", maintenance.repair_missing_files)
            if not args.keep_files:
                results["Ménage"] = _phase("Songs plus utilisées", maintenance.cleanup_unused_songs)
            results["tracks.json"] = _phase("tracks.json", maintenance.purge_dead_entries)
            results["Doublons"] = _phase("Doublons de playlists", maintenance.dedupe_playlists)
            results["Ordre"] = _phase("Ordre des playlists (comme Spotify)", playlists.reorder_all_like_spotify)
            results["Paroles"] = _phase("Paroles manquantes", maintenance.fetch_missing_lyrics)

    print("\n=== Bilan" + (" (dry run)" if DRY else "") + " ===")
    for key, n in sorted(STATS.items()):
        print(f"  {key} : {n}")
    failed = [k for k, ok in results.items() if not ok]
    print("=== Terminé " + ("✅" if not failed else f"avec erreurs : {', '.join(failed)} ❌") + " ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
