"""
accounts.py – The users of a Sonalex server.

Every user is a Jellyfin user with a music library of their own (they only see their songs), made
of **hard links** to the files on the server: a song two friends have takes the room of one file.
`<data>/accounts.json`:

    {"users":    {"<jellyfin user id>": {name, slug, provider, music, tracks, playlists, …}},
     "requests": {"<request id>": {name, jellyfinId, provider, status, …}}}

Signing up (from the app): the server creates the Jellyfin user right away, **disabled** (so the
password never has to be kept anywhere), and the request waits for an administrator. Approving it
creates the user's folder and library, enables the user and keeps the libraries apart; refusing it
deletes the Jellyfin user.

The first user (the server's own Jellyfin account, before there were several) keeps their files
where they were: `legacy`, nothing of theirs moves.
"""

import fcntl
import hashlib
import json
import re
import secrets
import shutil
import threading
import time
import unicodedata
from contextlib import contextmanager
from pathlib import Path

import requests

from config import ACCOUNTS_PATH, BACKEND_DIR, CONFIG, JELLYFIN_API_KEY, USERS_DIR

PROVIDERS = ("spotify", "deezer", "none")
MAX_PENDING = 10
_lock = threading.RLock()


class AccountError(Exception):
    """Something the person signing up / the admin should be told."""


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

def _read() -> dict:
    try:
        data = json.loads(ACCOUNTS_PATH.read_text(encoding="utf8"))
    except (OSError, ValueError):
        data = {}
    data.setdefault("users", {})
    data.setdefault("requests", {})
    return data


@contextmanager
def _editing():
    """Locked read-modify-write (the API and the nightly sync both write it)."""
    with _lock:
        ACCOUNTS_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(str(ACCOUNTS_PATH) + ".lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = _read()
            yield data
            tmp = ACCOUNTS_PATH.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf8")
            tmp.replace(ACCOUNTS_PATH)


def users() -> dict[str, dict]:
    return _read()["users"]


def user(jellyfin_id: str) -> dict | None:
    return users().get(_plain(jellyfin_id))


def by_slug(slug: str) -> dict | None:
    return next((a for a in users().values() if a["slug"] == slug), None)


def _plain(jellyfin_id: str) -> str:
    return (jellyfin_id or "").replace("-", "").lower()


def update(jellyfin_id: str, **fields) -> dict:
    with _editing() as data:
        account = data["users"].get(_plain(jellyfin_id))
        if not account:
            raise AccountError("Unknown user")
        account.update(fields)
        return dict(account)


def slugify(name: str) -> str:
    text = unicodedata.normalize("NFKD", name)
    text = "".join(c for c in text if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-") or "user"


# ---------------------------------------------------------------------------
# Jellyfin (with the server's API key: it sees and manages every user)
# ---------------------------------------------------------------------------

def _jf():
    import jellyfin

    return jellyfin


def _api(method: str, path: str, **kwargs) -> requests.Response:
    jf = _jf()
    kwargs.setdefault("timeout", 30)
    return requests.request(method, f"{jf.SERVER}{path}", headers=jf.HEADERS, **kwargs)


def multi_user_ready() -> bool:
    """Several users need the API key: a user session only sees its own libraries."""
    return bool(JELLYFIN_API_KEY)


def _libraries() -> list[dict]:
    r = _api("GET", "/Library/VirtualFolders")
    r.raise_for_status()
    return r.json()


def _jellyfin_users() -> list[dict]:
    r = _api("GET", "/Users")
    r.raise_for_status()
    return r.json()


def bootstrap() -> None:
    """The first time: the server's own account becomes the first user, its files where they are."""
    if users():
        return
    import jellyfin

    music = CONFIG.get("PATHS", "JELLYFIN_PATH")
    try:
        library = next((lib for lib in _libraries()
                        if any(Path(loc).resolve() == Path(music).resolve() for loc in lib.get("Locations") or [])),
                       None)
        me = next((u for u in _jellyfin_users() if _plain(u["Id"]) == _plain(jellyfin.USER_ID or "")), None)
    except requests.RequestException as e:
        print(f"[accounts] Jellyfin unreachable, accounts not set up yet: {e!r}", flush=True)
        return
    if not me:
        return
    from config import SPOTIFY_SYNC

    name = me["Name"][:1].upper() + me["Name"][1:]
    with _editing() as data:
        if data["users"]:
            return
        data["users"][_plain(me["Id"])] = {
            "id": _plain(me["Id"]), "name": name, "slug": slugify(name), "jellyfinName": me["Name"],
            "admin": bool((me.get("Policy") or {}).get("IsAdministrator")), "legacy": True,
            "provider": "spotify" if SPOTIFY_SYNC else "none",
            "home": str(BACKEND_DIR), "music": music,
            "tracks": CONFIG.get("PATHS", "TRACKS_JSON"), "playlists": CONFIG.get("PATHS", "PLAYLISTS_JSON"),
            "spotifyToken": str(BACKEND_DIR / "chosic_data.json"),
            "libraryId": library["ItemId"] if library else None,
            "createdAt": time.time(), "visible": True,
        }
    print(f"[accounts] {name}: premier utilisateur, bibliothèque {music}", flush=True)


# ---------------------------------------------------------------------------
# Signing up
# ---------------------------------------------------------------------------

def _check_name(name: str) -> str:
    name = re.sub(r"\s+", " ", (name or "").strip())
    if not 2 <= len(name) <= 32 or not re.fullmatch(r"[\w' .-]+", name):
        raise AccountError("Choose a first name of 2 to 32 letters.")
    return name


def deezer_profile(text: str) -> dict:
    """{"id", "name"} of a public Deezer profile, from its link or its number."""
    text = (text or "").strip()
    if text.startswith(("http://", "https://")) and ("deezer.page.link" in text or "link.deezer.com" in text):
        try:
            text = requests.head(text, allow_redirects=True, timeout=10).url
        except requests.RequestException:
            pass
    m = re.search(r"(?:profile|user)/(\d+)", text) or re.fullmatch(r"\s*(\d+)\s*", text)
    if not m:
        raise AccountError("That doesn't look like a Deezer profile link.")
    try:
        data = requests.get(f"https://api.deezer.com/user/{m.group(1)}", timeout=10).json()
    except (requests.RequestException, ValueError):
        raise AccountError("Deezer can't be reached right now, try again.")
    if data.get("error"):
        raise AccountError("No public Deezer profile with that link.")
    return {"id": str(data["id"]), "name": data.get("name") or ""}


def request_account(name: str, password: str, provider: str, deezer: str | None = None) -> dict:
    """A new user asks to join. Returns {"id", "secret"}: the app follows its request with them."""
    if not multi_user_ready():
        raise AccountError("This server isn't set up for several users yet.")
    name = _check_name(name)
    if len(password or "") < 6:
        raise AccountError("Choose a password of at least 6 characters.")
    if provider not in PROVIDERS:
        raise AccountError("Unknown music service.")
    profile = deezer_profile(deezer or "") if provider == "deezer" else None
    with _lock:
        data = _read()
        taken = {a["name"].lower() for a in data["users"].values()} | {a["slug"] for a in data["users"].values()}
        pending = [r for r in data["requests"].values() if r["status"] == "pending"]
        if name.lower() in taken or slugify(name) in taken or any(r["name"].lower() == name.lower() for r in pending):
            raise AccountError("Someone already uses that name on this server.")
        if len(pending) >= MAX_PENDING:
            raise AccountError("Too many requests are waiting: ask the server's owner.")
        if any(u["Name"].lower() == name.lower() for u in _jellyfin_users()):
            raise AccountError("Someone already uses that name on this server.")
        r = _api("POST", "/Users/New", json={"Name": name, "Password": password})
        if not r.ok:
            raise AccountError("The server couldn't create the account.")
        created = r.json()
        _set_policy(created["Id"], disabled=True, folders=[])
        request_id, secret = secrets.token_urlsafe(12), secrets.token_urlsafe(24)
        with _editing() as data:
            data["requests"][request_id] = {
                "id": request_id, "name": name, "jellyfinId": _plain(created["Id"]), "provider": provider,
                "deezer": profile, "secret": hashlib.sha256(secret.encode()).hexdigest(),
                "createdAt": time.time(), "status": "pending",
            }
    print(f"[accounts] demande de {name} ({provider})", flush=True)
    return {"id": request_id, "secret": secret, "name": name}


def request_status(request_id: str, secret: str) -> dict:
    request = _read()["requests"].get(request_id)
    if not request or not secrets.compare_digest(request["secret"], hashlib.sha256((secret or "").encode()).hexdigest()):
        raise AccountError("Unknown request.")
    return {"status": request["status"], "name": request["name"]}


def pending_requests() -> list[dict]:
    return sorted(({k: v for k, v in r.items() if k != "secret"}
                   for r in _read()["requests"].values() if r["status"] == "pending"),
                  key=lambda r: r["createdAt"])


# ---------------------------------------------------------------------------
# Admin decisions
# ---------------------------------------------------------------------------

def approve(request_id: str) -> dict:
    with _lock:
        request = _read()["requests"].get(request_id)
        if not request or request["status"] != "pending":
            raise AccountError("This request isn't waiting anymore.")
        name, slug = request["name"], slugify(request["name"])
        home = USERS_DIR / slug
        music = home / "Musics"
        music.mkdir(parents=True, exist_ok=True)
        (home / "logs").mkdir(exist_ok=True)
        for f in ("tracks.json", "playlists.json"):
            if not (home / f).exists():
                (home / f).write_text("{}", encoding="utf8")
        library_id = _create_library(f"Sonalex – {name}", music)
        account = {
            "id": request["jellyfinId"], "name": name, "slug": slug, "jellyfinName": name, "admin": False,
            "legacy": False, "provider": request["provider"],
            "deezerId": (request.get("deezer") or {}).get("id"), "deezerName": (request.get("deezer") or {}).get("name"),
            "home": str(home), "music": str(music),
            "tracks": str(home / "tracks.json"), "playlists": str(home / "playlists.json"),
            "spotifyToken": str(home / "spotify.json"), "libraryId": library_id,
            "createdAt": time.time(), "visible": True,
        }
        with _editing() as data:
            data["users"][account["id"]] = account
            data["requests"][request_id]["status"] = "approved"
            data["requests"][request_id]["decidedAt"] = time.time()
        isolate_libraries()
        _set_policy(account["id"], disabled=False)
    print(f"[accounts] {name} accepté·e : bibliothèque {music}", flush=True)
    return account


def deny(request_id: str) -> None:
    with _editing() as data:
        request = data["requests"].get(request_id)
        if not request or request["status"] != "pending":
            raise AccountError("This request isn't waiting anymore.")
        request["status"] = "denied"
        request["decidedAt"] = time.time()
        jellyfin_id = request["jellyfinId"]
    _api("DELETE", f"/Users/{jellyfin_id}")


def remove(jellyfin_id: str, delete_files: bool = True) -> None:
    """Deletes a user: their Jellyfin user, their library, their links (shared files stay)."""
    account = user(jellyfin_id)
    if not account:
        raise AccountError("Unknown user")
    if account.get("legacy") or account.get("admin"):
        raise AccountError("The server's owner can't be removed from here.")
    if account.get("libraryId"):
        name = next((lib["Name"] for lib in _libraries() if lib["ItemId"] == account["libraryId"]), None)
        if name:
            _api("DELETE", "/Library/VirtualFolders", params={"name": name, "refreshLibrary": "false"})
    _api("DELETE", f"/Users/{account['id']}")
    with _editing() as data:
        data["users"].pop(account["id"], None)
    if delete_files and account.get("home") and Path(account["home"]).is_relative_to(USERS_DIR):
        # Hard links: removing them frees only what nobody else has.
        shutil.rmtree(account["home"], ignore_errors=True)


def _create_library(name: str, folder: Path) -> str:
    existing = next((lib for lib in _libraries() if lib["Name"] == name), None)
    if not existing:
        r = _api("POST", "/Library/VirtualFolders", json={"LibraryOptions": {}},
                 params={"name": name, "collectionType": "music", "paths": str(folder), "refreshLibrary": "true"})
        r.raise_for_status()
        existing = next((lib for lib in _libraries() if lib["Name"] == name), None)
    if not existing:
        raise AccountError("Jellyfin didn't create the library.")
    return existing["ItemId"]


def _set_policy(jellyfin_id: str, disabled: bool | None = None, folders: list[str] | None = None) -> None:
    r = _api("GET", f"/Users/{jellyfin_id}")
    r.raise_for_status()
    policy = r.json()["Policy"]
    if disabled is not None:
        policy["IsDisabled"] = disabled
    if folders is not None:
        policy["EnableAllFolders"] = False
        policy["EnabledFolders"] = folders
    _api("POST", f"/Users/{jellyfin_id}/Policy", json=policy).raise_for_status()


def isolate_libraries() -> None:
    """Every user sees their own music library, and every library that isn't someone's (films…)."""
    personal = {a["libraryId"]: a["id"] for a in users().values() if a.get("libraryId")}
    if len(personal) < 2:
        return  # one music library: nothing to keep apart (and nothing to change)
    shared = [lib["ItemId"] for lib in _libraries() if lib["ItemId"] not in personal]
    for u in _jellyfin_users():
        own = [lib for lib, owner in personal.items() if owner == _plain(u["Id"])]
        wanted = sorted(shared + own)
        policy = u.get("Policy") or {}
        if not policy.get("EnableAllFolders") and sorted(policy.get("EnabledFolders") or []) == wanted:
            continue
        _set_policy(u["Id"], folders=wanted)
