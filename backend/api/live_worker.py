"""
live_worker.py – Runs the live Jellyfin → Spotify sync inside the API process.

Three sources of work, one worker thread (so pushes never run in parallel, and never during
the nightly sync: each job takes the shared sync lock):

  1. Jellyfin's websocket: `UserDataChanged` arrives the instant a song is (un)favorited;
  2. the app: POST /api/sync/playlist/{id} right after it edits a playlist (fire-and-forget,
     the app doesn't wait for Spotify);
  3. a safety pass every few minutes (anything changed elsewhere, e.g. Jellyfin web,
     or a push that failed because Spotify was down).

The nightly full_refreshing.py still runs at midnight for the Spotify → Jellyfin direction
(downloads) and as a last check.

Several users: a job is for one user (their slug: their Spotify account, their Jellyfin user) and
runs in a process of its own (user_jobs.py). Only users synced with Spotify have live pushes
(Deezer can't be written to).
"""

import asyncio
import json
import threading
import time
from collections import OrderedDict
from pathlib import Path

from .common import JELLYFIN_URL

RECONCILE_EVERY = 300  # seconds
DEBOUNCE = 2.0  # wait a bit so several quick edits become one push


class LiveWorker:
    def __init__(self):
        self._jobs: "OrderedDict[tuple, float]" = OrderedDict()  # job → earliest run time
        self._cv = threading.Condition()
        self._started = False
        self.last_reconcile = 0.0
        self.last_error: str | None = None
        self.favorite_events = 0
        self.websocket_connected = False

    # -- queue ---------------------------------------------------------------

    def submit(self, *job, delay: float = DEBOUNCE):
        with self._cv:
            self._jobs.pop(job, None)  # coalesce: same playlist edited again → one push
            self._jobs[job] = time.time() + delay
            self._cv.notify()

    def _next_job(self):
        with self._cv:
            while True:
                now = time.time()
                ready = [j for j, t in self._jobs.items() if t <= now]
                if ready:
                    job = ready[0]
                    del self._jobs[job]
                    return job
                wait = min(self._jobs.values()) - now if self._jobs else None
                self._cv.wait(timeout=wait)

    def _run(self):
        from user_jobs import run

        while True:
            job = self._next_job()
            kind, slug = job[0], job[1]
            try:
                # The job waits (sync lock) while the nightly sync runs; it will be done right after.
                if kind == "playlist":
                    result = run(slug, "push-playlist", job[2])
                elif kind == "favorites":
                    # Merge every favorite change of this user queued meanwhile into this push.
                    ids = set(job[2])
                    with self._cv:
                        for other in [j for j in self._jobs if j[0] == "favorites" and j[1] == slug]:
                            ids |= set(other[2])
                            del self._jobs[other]
                    result = run(slug, "push-favorites", *sorted(ids))
                elif kind == "reconcile":
                    result = run(slug, "reconcile")
                    self.last_reconcile = time.time()
                else:
                    continue
                if result.get("error"):
                    raise RuntimeError(result["error"])
                self.last_error = None
            except Exception as e:
                self.last_error = f"{kind} ({slug}): {e!r}"
                print(f"[live-sync] ⚠️ {kind} ({slug}) échoué ({e!r}) → nouvel essai au prochain passage", flush=True)

    def _poll(self):
        time.sleep(30)  # let the API start
        while True:
            for slug in spotify_users():
                self.submit("reconcile", slug, delay=0)
            time.sleep(RECONCILE_EVERY)

    # -- Jellyfin websocket ------------------------------------------------------

    def _listen(self):
        asyncio.run(self._listen_forever())

    async def _listen_forever(self):
        import websockets

        import jellyfin

        while True:
            try:
                token = _token_from_headers(jellyfin.HEADERS)
                url = JELLYFIN_URL.replace("http", "ws", 1) + f"/socket?ApiKey={token}&deviceId=musique-live-sync"
                async with websockets.connect(url, ping_interval=30, max_size=None) as ws:
                    self.websocket_connected = True
                    keep_alive = None
                    async for raw in ws:
                        msg = json.loads(raw)
                        kind = msg.get("MessageType")
                        if kind == "ForceKeepAlive":
                            # Jellyfin wants a KeepAlive every <Data> s or so. Its own "KeepAlive"
                            # messages are the answers to ours: answering those again made an
                            # endless ping-pong (thousands per second, a CPU core at full load).
                            if keep_alive is None:
                                keep_alive = asyncio.create_task(_keep_alive(ws, float(msg.get("Data") or 60) / 2))
                        elif kind == "UserDataChanged":
                            data = msg.get("Data") or {}
                            slug = spotify_user_slug(data.get("UserId", ""))
                            if slug is False:
                                continue  # not someone synced with Spotify
                            ids = tuple(sorted({u["ItemId"] for u in data.get("UserDataList", [])
                                                if "IsFavorite" in u and u.get("ItemId")}))
                            if ids:
                                self.favorite_events += 1
                                self.submit("favorites", slug, ids, delay=1.0)
            except Exception as e:
                self.websocket_connected = False
                print(f"[live-sync] websocket Jellyfin coupé ({e!r}), reconnexion…", flush=True)
            await asyncio.sleep(10)

    def start(self):
        if self._started:
            return
        self._started = True
        for target in (self._run, self._poll, self._listen):
            threading.Thread(target=target, daemon=True, name=f"live-sync-{target.__name__}").start()
        print("[live-sync] démarré (websocket Jellyfin + passage toutes les "
              f"{RECONCILE_EVERY // 60} min)", flush=True)


async def _keep_alive(ws, every: float):
    try:
        while True:
            await ws.send(json.dumps({"MessageType": "KeepAlive"}))
            await asyncio.sleep(max(5.0, every))
    except Exception:
        pass  # the socket closed: _listen_forever reconnects


def spotify_users() -> list:
    """Slugs of the users synced with Spotify ([None] = the single user of a server without accounts)."""
    import accounts

    found = accounts.users()
    if not found:
        return [None]
    return [a["slug"] for a in found.values() if a.get("provider") == "spotify" and Path(a["spotifyToken"]).exists()]


def spotify_user_slug(jellyfin_user_id: str):
    """Slug of the Spotify-synced user behind a Jellyfin user id; None: single user; False: none."""
    import accounts

    import jellyfin

    found = accounts.users()
    if not found:
        same = jellyfin_user_id.replace("-", "") == (jellyfin.USER_ID or "").replace("-", "")
        return None if same else False
    account = accounts.user(jellyfin_user_id)
    if account and account.get("provider") == "spotify" and Path(account["spotifyToken"]).exists():
        return account["slug"]
    return False


def _token_from_headers(headers: dict) -> str:
    auth = (headers or {}).get("Authorization", "")
    marker = 'Token="'
    return auth[auth.index(marker) + len(marker):].split('"')[0] if marker in auth else ""


LIVE = LiveWorker()
