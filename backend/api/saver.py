"""
saver.py – Keeps an online song for good, in the library of the user who asked.

When a streamed song is liked or added to a playlist from the app, it is filed into the user's
library exactly like the songs the sync downloads (same Song model, tags, covers, tracks.json
entry), so the Spotify / Deezer sync keeps working on it. If someone on the server already has it,
it's a hard link to their file: instant, and no room taken. Then the favorite / playlist action is
applied in Jellyfin, as the user.

The filing itself runs for the user in a process of their own (user_jobs.py save).
"""

import threading

from .library import LIBRARY, jf_request
from .streamer import STREAMER

_save_lock = threading.Lock()


def save(key: str, favorite: bool, playlist_id: str | None, user_headers: dict, user_id: str) -> dict:
    import accounts
    import library_index
    from user_jobs import run

    account = accounts.user(user_id)
    # Not on the server yet: the streamed file (downloaded while it played) is what gets kept.
    source = "-" if library_index.find_key(key) else str(STREAMER.wait_done(key).path)
    with _save_lock:  # one at a time: Jellyfin indexes them one after the other anyway
        result = run(account["slug"] if account else None, "save", key, source, timeout=900)
    if result.get("error"):
        if "not found" in result["error"]:
            raise LookupError(result["error"])
        raise RuntimeError(result["error"])
    path = result["path"]

    # Rescan only the album (or artist) folder: seconds instead of a whole-library scan.
    LIBRARY.scan_folder_of(path)
    item_id = LIBRARY.wait_for_item(path)
    if not item_id:
        raise RuntimeError("Jellyfin hasn’t indexed this song yet, try again in a moment.")

    if favorite:
        jf_request("POST", f"/UserFavoriteItems/{item_id}", headers=user_headers, params={"userId": user_id})
    if playlist_id:
        jf_request("POST", f"/Playlists/{playlist_id}/Items", headers=user_headers,
                   params={"ids": item_id, "userId": user_id})

    r = jf_request("GET", f"/Items/{item_id}", headers=user_headers, params={"userId": user_id})
    r.raise_for_status()
    return r.json()
