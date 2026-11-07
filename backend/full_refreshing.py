"""
full_refreshing.py – Synchronisation complète Spotify ↔ Jellyfin (timer systemd, chaque nuit)

Jellyfin est maître. Les changements faits dans Jellyfin (app, web) sont déjà poussés vers
Spotify en direct par l'API (live_sync.py) ; ce run de nuit :
  0. repousse ce qui aurait été raté côté Jellyfin → Spotify (Spotify en panne, API arrêtée…)
  1. synchronise les likes (nouveaux likes Spotify → téléchargés + favoris Jellyfin)
  2. synchronise les playlists (dans les deux sens, téléchargements)
  3. fait le ménage (fichiers manquants, doublons, paroles, songs plus utilisées)

Une phase qui plante n'empêche pas les suivantes. Un seul sync à la fois (verrou partagé avec
l'API). Journal : <données>/logs/sync-AAAA-MM-JJ.log (30 derniers jours gardés).
"""

import os
import sys
import time
import traceback
from datetime import date
from pathlib import Path

BACKEND = Path(__file__).resolve().parent
os.chdir(BACKEND)
sys.path.insert(0, str(BACKEND))

from config import LOG_DIR  # noqa: E402


class _Tee:
    def __init__(self, *streams):
        self.streams = streams

    def write(self, data):
        for s in self.streams:
            s.write(data)
            s.flush()

    def flush(self):
        for s in self.streams:
            s.flush()


def _setup_logging():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    for old in sorted(LOG_DIR.glob("sync-*.log"))[:-30]:
        old.unlink(missing_ok=True)
    log = open(LOG_DIR / f"sync-{date.today().isoformat()}.log", "a", encoding="utf8", buffering=1)
    sys.stdout = _Tee(sys.__stdout__, log)
    sys.stderr = _Tee(sys.__stderr__, log)
    print(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} =====")


def _phase(name, fn):
    print(f"\n=== {name} ===")
    started = time.time()
    try:
        fn()
        print(f"=== {name} : OK ({time.time() - started:.0f} s) ===")
        return True
    except Exception:
        print(f"=== {name} : ÉCHEC ===")
        traceback.print_exc()
        return False


def main():
    _setup_logging()
    from sync_lock import sync_lock

    with sync_lock():  # attend la fin d'une synchro en direct en cours
        # Imports après le verrou : les modules lisent leur état à l'import.
        import jellyfin
        import live_sync
        import maintenance
        import playlists
        from liked import full_check_likes
        from sync import sync_playlists

        playlists.reload_state()
        jellyfin.refresh_library()
        time.sleep(20)  # laisse Jellyfin indexer les nouveaux fichiers
        jellyfin.build_path_index()

        results = {
            "Jellyfin → Spotify": _phase("Jellyfin → Spotify (rattrapage)", live_sync.reconcile),
            "Likes": _phase("Likes ❤️", full_check_likes),
            "Playlists": _phase("Playlists", sync_playlists),
        }
        playlists.reload_state()
        results["Fichiers manquants"] = _phase("Fichiers manquants", maintenance.repair_missing_files)
        results["Ménage"] = _phase("Songs plus utilisées", maintenance.cleanup_unused_songs)
        results["tracks.json"] = _phase("tracks.json", maintenance.purge_dead_entries)
        results["Doublons"] = _phase("Doublons de playlists", maintenance.dedupe_playlists)
        results["Ordre"] = _phase("Ordre des playlists (comme Spotify)", playlists.reorder_all_like_spotify)
        results["Mix"] = _phase("Analyse Mix (tempo, temps, tonalité)", maintenance.analyze_for_mix)
        results["Paroles"] = _phase("Paroles manquantes", maintenance.fetch_missing_lyrics)
        results["Paroles synchronisées"] = _phase("Paroles synchronisées", maintenance.upgrade_plain_lyrics)

    failed = [k for k, ok in results.items() if not ok]
    print("\n=== Terminé " + ("✅" if not failed else f"avec erreurs : {', '.join(failed)} ❌") + " ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
