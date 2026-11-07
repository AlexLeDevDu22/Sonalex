"""
social.py – What the users of a server listen to: their plays, their profiles, the songs they share.

The apps report every song they've played (`POST /api/me/plays`, with how long it was heard) into
`<data>/plays.db` (SQLite): each user's history, their stats, the admin's dashboard. Before that
history fills up, Jellyfin's own play counts stand in.

A song two users have is one file linked into both libraries (accounts.py): "who else has it, who
likes it" compares files (device + inode), whatever the Jellyfin item ids.
"""

import os
import sqlite3
import threading
import time
from collections import Counter
from pathlib import Path

from config import DATA_DIR

from .common import TTLCache

DB = DATA_DIR / "plays.db"
_lock = threading.Lock()
_files = TTLCache(ttl=300, max_items=200)  # user id → their songs: {(dev, ino): (item id, favorite)}


def _db() -> sqlite3.Connection:
    con = sqlite3.connect(DB, timeout=10)
    con.row_factory = sqlite3.Row
    return con


def init():
    with _lock, _db() as con:
        con.executescript("""
            CREATE TABLE IF NOT EXISTS plays (
                user_id TEXT NOT NULL, item_id TEXT, title TEXT, artist TEXT, album TEXT,
                art_id TEXT, art_tag TEXT, duration REAL, listened REAL, at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS plays_user_at ON plays (user_id, at);
            CREATE TABLE IF NOT EXISTS moments (
                user_id TEXT PRIMARY KEY, item_id TEXT, title TEXT, artist TEXT, album TEXT,
                art_id TEXT, art_tag TEXT, at REAL);
        """)
        for table in ("plays", "moments"):  # artwork URL of online songs (not Jellyfin items)
            if "art" not in [c[1] for c in con.execute(f"PRAGMA table_info({table})")]:
                con.execute(f"ALTER TABLE {table} ADD COLUMN art TEXT")


def record_play(user_id: str, p: dict):
    listened = float(p.get("listened") or 0)
    if listened < 10:
        return  # skipped at once: not a play
    with _lock, _db() as con:
        con.execute("INSERT INTO plays (user_id, item_id, title, artist, album, art_id, art_tag, duration, listened, at, art) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (user_id, p.get("itemId"), p.get("title"), p.get("artist"), p.get("album"), p.get("artId"),
                     p.get("artTag"), float(p.get("duration") or 0), listened, float(p.get("at") or time.time()),
                     p.get("art")))


def set_moment(user_id: str, m: dict | None):
    with _lock, _db() as con:
        if not m:
            con.execute("DELETE FROM moments WHERE user_id = ?", (user_id,))
        else:
            con.execute("INSERT OR REPLACE INTO moments (user_id, item_id, title, artist, album, art_id, art_tag, at, art) "
                        "VALUES (?,?,?,?,?,?,?,?,?)",
                        (user_id, m.get("itemId"), m.get("title"), m.get("artist"), m.get("album"),
                         m.get("artId"), m.get("artTag"), time.time(), m.get("art")))


def moment(user_id: str) -> dict | None:
    with _db() as con:
        row = con.execute("SELECT * FROM moments WHERE user_id = ?", (user_id,)).fetchone()
    return _song(row) if row else None


def _song(row) -> dict:
    return {"itemId": row["item_id"], "title": row["title"], "artist": row["artist"], "album": row["album"],
            "artId": row["art_id"], "artTag": row["art_tag"], "art": row["art"] if "art" in row.keys() else None}


def stats(user_id: str, days: int = 30) -> dict:
    """Listening of a user: totals, per day (14 days), per hour, top songs / artists, latest plays."""
    now = time.time()
    since = now - days * 86400
    with _db() as con:
        rows = con.execute("SELECT * FROM plays WHERE user_id = ? AND at >= ? ORDER BY at DESC",
                           (user_id, min(since, now - 14 * 86400))).fetchall()
        total = con.execute("SELECT COUNT(*), COALESCE(SUM(listened), 0), MIN(at) FROM plays WHERE user_id = ?",
                            (user_id,)).fetchone()
    recent = [r for r in rows if r["at"] >= since]
    today = time.localtime(now)
    midnight = time.mktime((today.tm_year, today.tm_mon, today.tm_mday, 0, 0, 0, 0, 0, -1))
    by_day = [0.0] * 14
    for r in rows:
        d = int((midnight - r["at"]) // 86400) + 1 if r["at"] < midnight else 0
        if 0 <= d < 14:
            by_day[13 - d] += r["listened"] / 60
    by_hour = [0.0] * 24
    for r in recent:
        by_hour[time.localtime(r["at"]).tm_hour] += r["listened"] / 60
    songs = Counter((r["title"], r["artist"]) for r in recent)
    first = {}
    for r in recent:
        first.setdefault((r["title"], r["artist"]), r)
    artists = Counter()
    for r in recent:
        artists[(r["artist"] or "").split(",")[0].strip()] += 1
    return {
        "plays": total[0], "minutes": round(total[1] / 60), "since": total[2],
        "periodDays": days, "periodPlays": len(recent), "periodMinutes": round(sum(r["listened"] for r in recent) / 60),
        "byDay": [round(m) for m in by_day], "byHour": [round(m) for m in by_hour],
        "topSongs": [{**_song(first[k]), "plays": n} for k, n in songs.most_common(10)],
        "topArtists": [{"name": a, "plays": n} for a, n in artists.most_common(8) if a],
        "recent": [{**_song(r), "at": r["at"]} for r in rows[:12]],
    }


def last_played(user_id: str) -> float | None:
    with _db() as con:
        row = con.execute("SELECT MAX(at) FROM plays WHERE user_id = ?", (user_id,)).fetchone()
    return row[0]


def activity(limit: int = 50) -> list[dict]:
    with _db() as con:
        rows = con.execute("SELECT * FROM plays ORDER BY at DESC LIMIT ?", (limit,)).fetchall()
    return [{**_song(r), "userId": r["user_id"], "at": r["at"], "listened": r["listened"]} for r in rows]


def totals_since(seconds: float) -> dict[str, float]:
    """Minutes listened per user over the last `seconds`."""
    with _db() as con:
        rows = con.execute("SELECT user_id, SUM(listened) FROM plays WHERE at >= ? GROUP BY user_id",
                           (time.time() - seconds,)).fetchall()
    return {r[0]: round(r[1] / 60) for r in rows}


# ---------------------------------------------------------------------------
# The same song in several libraries
# ---------------------------------------------------------------------------

def _songs_of(user_id: str) -> dict:
    """{(device, inode): (item id, favorite)} of a user's library (cached 5 min)."""
    hit = _files.get(user_id)
    if hit is not None:
        return hit
    from .library import jf_request

    r = jf_request("GET", "/Items", admin=True, params={
        "userId": user_id, "Recursive": "true", "IncludeItemTypes": "Audio", "Fields": "Path",
        "EnableUserData": "true", "Limit": 100000})
    out = {}
    if r.ok:
        for item in r.json().get("Items", []):
            try:
                st = os.stat(item["Path"])
            except (KeyError, OSError):
                continue
            out[(st.st_dev, st.st_ino)] = (item["Id"], bool((item.get("UserData") or {}).get("IsFavorite")))
    _files.set(user_id, out)
    return out


def file_of(item_id: str) -> tuple[int, int] | None:
    from .library import jf_request

    r = jf_request("GET", "/Items", admin=True, params={"Ids": item_id, "Fields": "Path"})
    items = r.json().get("Items", []) if r.ok else []
    try:
        st = os.stat(items[0]["Path"])
    except (IndexError, KeyError, OSError):
        return None
    return st.st_dev, st.st_ino


def who_has(item_id: str, viewer: str, users: dict) -> list[dict]:
    """The other users who have this song in their library, and whether they like it."""
    f = file_of(item_id)
    if not f:
        return []
    out = []
    for uid, account in users.items():
        if uid == viewer or not account.get("visible", True):
            continue
        mine = _songs_of(uid).get(f)
        if mine:
            out.append({"id": uid, "name": account["name"], "liked": mine[1]})
    return sorted(out, key=lambda u: (not u["liked"], u["name"]))


def own_item(viewer: str, item_id: str) -> str | None:
    """The viewer's own item for a song of another library (same file), to play it from there."""
    f = file_of(item_id)
    mine = _songs_of(viewer).get(f) if f else None
    return mine[0] if mine else None


def library_size(account: dict) -> dict:
    """Songs of a library, and the room they take: their own (only they have it) and shared."""
    songs, own, shared = 0, 0, 0
    root = Path(account["music"])
    for path in root.rglob("*.mp3") if root.exists() else []:
        try:
            st = path.stat()
        except OSError:
            continue
        songs += 1
        if st.st_nlink > 1:
            shared += st.st_size
        else:
            own += st.st_size
    return {"songs": songs, "ownBytes": own, "sharedBytes": shared}
