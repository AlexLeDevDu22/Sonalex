"""
sync_lock.py – One Spotify ↔ Jellyfin sync at a time.

The nightly sync (full_refreshing.py, its own process) and the live sync (inside the API)
both read-modify-write playlists.json and push to Spotify: they take this file lock first.
"""

import fcntl
import os
import time
from contextlib import contextmanager

from config import DATA_DIR

LOCK_PATH = str(DATA_DIR / ".sync.lock")


class SyncBusy(Exception):
    pass


@contextmanager
def sync_lock(timeout: float | None = None):
    """Holds the sync lock. `timeout=None` waits as long as needed; otherwise raises SyncBusy."""
    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    with open(LOCK_PATH, "w") as f:
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if deadline is not None and time.monotonic() >= deadline:
                    raise SyncBusy("another sync is running")
                time.sleep(1)
        try:
            f.write(f"{os.getpid()}\n")
            f.flush()
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)
