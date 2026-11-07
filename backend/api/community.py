"""
community.py – Several people on one server: signing up, profiles, what friends listen to, and the
admin's side (requests, users, the server's state). See accounts.py and social.py.

    /api/accounts/*   no sign-in (someone asking to join)
    /api/me/*         the signed-in user
    /api/social/*     the other users, as a signed-in user sees them
    /api/admin/*      the server's owner (a Jellyfin administrator)
    /admin            the admin's web page
"""

import os
import shutil
import threading
import time
from pathlib import Path

import requests
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse
from pydantic import BaseModel

import accounts
from config import DATA_DIR, JELLYFIN_URL, ONLINE, SIGNUPS, SPOTIFY_SYNC

from . import social
from .auth import Auth, admin, auth
from .connect import HUB

router = APIRouter()
_attempts: dict[str, list[float]] = {}  # IP → sign-up requests (one hour)


def _error(e: Exception, status: int = 400):
    raise HTTPException(status, str(e))


def _public(account: dict) -> dict:
    return {"id": account["id"], "name": account["name"], "provider": account.get("provider"),
            "admin": bool(account.get("admin")), "joinedAt": account.get("createdAt")}


def _admin_ids() -> list[str]:
    return [a["id"] for a in accounts.users().values() if a.get("admin")]


# ---------------------------------------------------------------------------
# Signing up (no account yet)
# ---------------------------------------------------------------------------

@router.get("/api/accounts/info")
def accounts_info():
    """What the sign-up screen needs to know about this server."""
    from spotify_auth import client_id

    try:
        server_name = requests.get(f"{JELLYFIN_URL}/System/Info/Public", timeout=5).json().get("ServerName")
    except (requests.RequestException, ValueError):
        server_name = None
    owners = [a["name"] for a in accounts.users().values() if a.get("admin")]
    return {"signups": SIGNUPS and accounts.multi_user_ready(), "serverName": server_name, "owner": owners[0] if owners else None,
            "providers": {"spotify": SPOTIFY_SYNC and bool(client_id()), "deezer": SPOTIFY_SYNC, "none": True}}


class SignUpBody(BaseModel):
    name: str
    password: str
    provider: str = "none"
    deezer: str | None = None


@router.post("/api/accounts/request")
async def account_request(body: SignUpBody, request: Request):
    if not SIGNUPS:
        raise HTTPException(403, "This server doesn't take new users.")
    ip = request.client.host if request.client else "?"
    recent = [t for t in _attempts.get(ip, []) if time.time() - t < 3600]
    if len(recent) >= 5:
        raise HTTPException(429, "Too many requests, try again later.")
    _attempts[ip] = recent + [time.time()]
    if body.provider in ("spotify", "deezer") and not SPOTIFY_SYNC:
        body.provider = "none"
    try:
        created = await run_in_threadpool(accounts.request_account, body.name, body.password, body.provider, body.deezer)
    except accounts.AccountError as e:
        _error(e)
    await HUB.notify(_admin_ids(), {"type": "accountRequest", "name": created["name"]})
    return created


@router.get("/api/accounts/request/{request_id}")
def account_request_status(request_id: str, secret: str):
    try:
        return accounts.request_status(request_id, secret)
    except accounts.AccountError as e:
        _error(e, 404)


# ---------------------------------------------------------------------------
# Me
# ---------------------------------------------------------------------------

def _me(a: Auth) -> dict:
    account = a.account
    if not account:
        raise HTTPException(404, "No Sonalex account for this user")
    return account


@router.get("/api/me")
def me(a: Auth = Depends(auth)):
    account = _me(a)
    return {**_public(account), "visible": account.get("visible", True),
            "spotifyConnected": Path(account.get("spotifyToken") or "/nonexistent").exists(),
            "deezerName": account.get("deezerName"), "pending": len(accounts.pending_requests()) if account.get("admin") else 0}


class PlayBody(BaseModel):
    itemId: str | None = None
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    artId: str | None = None
    artTag: str | None = None
    art: str | None = None
    duration: float | None = None
    listened: float = 0
    at: float | None = None


@router.post("/api/me/plays", status_code=204)
def me_play(body: PlayBody, a: Auth = Depends(auth)):
    social.record_play(a.user_id, body.model_dump())


@router.put("/api/me/moment", status_code=204)
def me_moment(body: PlayBody, a: Auth = Depends(auth)):
    social.set_moment(a.user_id, body.model_dump() if body.title else None)


class VisibleBody(BaseModel):
    visible: bool


@router.put("/api/me/visible", status_code=204)
def me_visible(body: VisibleBody, a: Auth = Depends(auth)):
    accounts.update(_me(a)["id"], visible=body.visible)


@router.get("/api/me/spotify")
def me_spotify_config(a: Auth = Depends(auth)):
    """How the app signs the user in to Spotify (the server's Spotify app)."""
    from spotify_auth import REDIRECT_URI, SCOPES, client_id

    if not SPOTIFY_SYNC or not client_id():
        raise HTTPException(404, "Spotify isn't set up on this server")
    return {"clientId": client_id(), "redirectUri": REDIRECT_URI, "scopes": SCOPES}


class SpotifyBody(BaseModel):
    code: str
    verifier: str
    redirectUri: str | None = None


@router.post("/api/me/spotify")
async def me_spotify(body: SpotifyBody, a: Auth = Depends(auth)):
    import spotify_auth

    account = _me(a)
    try:
        profile = await run_in_threadpool(spotify_auth.connect, account, body.code, body.verifier,
                                          body.redirectUri or spotify_auth.REDIRECT_URI)
    except RuntimeError as e:
        _error(e)
    accounts.update(account["id"], provider="spotify", spotifyUser=profile["id"])
    _sync_soon(account["slug"])
    return profile


class DeezerBody(BaseModel):
    profile: str


@router.put("/api/me/deezer")
async def me_deezer(body: DeezerBody, a: Auth = Depends(auth)):
    account = _me(a)
    try:
        profile = await run_in_threadpool(accounts.deezer_profile, body.profile)
    except accounts.AccountError as e:
        _error(e)
    accounts.update(account["id"], provider="deezer", deezerId=profile["id"], deezerName=profile["name"])
    _sync_soon(account["slug"])
    return profile


@router.post("/api/me/sync", status_code=202)
def me_sync(a: Auth = Depends(auth)):
    """Sync now (Spotify / Deezer) instead of waiting for the night."""
    account = _me(a)
    if account.get("provider") not in ("spotify", "deezer"):
        raise HTTPException(400, "No music service connected")
    _sync_soon(account["slug"])
    return {"queued": True}


_syncing: dict[str, object] = {}  # slug → the running sync process


def _sync_soon(slug: str):
    """The user's full sync, in the background (first import after connecting a service)."""
    import subprocess
    import sys

    from config import BACKEND_DIR

    if slug in _syncing:
        return

    def run():
        proc = subprocess.Popen([sys.executable, str(BACKEND_DIR / "full_refreshing.py")],
                                env={**os.environ, "SONALEX_USER": slug})
        _syncing[slug] = proc
        try:
            proc.wait(timeout=6 * 3600)
        except subprocess.TimeoutExpired:
            proc.kill()
        finally:
            _syncing.pop(slug, None)

    threading.Thread(target=run, daemon=True).start()


def _stop_sync(slug: str):
    proc = _syncing.pop(slug, None)
    if proc:
        proc.terminate()


# ---------------------------------------------------------------------------
# Social
# ---------------------------------------------------------------------------

@router.get("/api/social/users")
def social_users(a: Auth = Depends(auth)):
    week = social.totals_since(7 * 86400)
    out = []
    for uid, account in accounts.users().items():
        if not account.get("visible", True) and uid != a.user_id:
            continue
        out.append({**_public(account), "isMe": uid == a.user_id, "weekMinutes": week.get(uid, 0),
                    "nowPlaying": HUB.now_playing(uid), "moment": social.moment(uid)})
    return {"users": sorted(out, key=lambda u: (not u["isMe"], u["nowPlaying"] is None, -u["weekMinutes"]))}


def _profile(uid: str, account: dict) -> dict:
    from .library import jf_request

    favorites = jf_request("GET", "/Items", admin=True, params={
        "userId": uid, "Recursive": "true", "IncludeItemTypes": "Audio", "Filters": "IsFavorite", "Limit": 0,
        "EnableTotalRecordCount": "true"})
    stats = social.stats(uid)
    if not stats["topSongs"]:
        # No history from the app yet: Jellyfin's play counts.
        r = jf_request("GET", "/Items", admin=True, params={
            "userId": uid, "Recursive": "true", "IncludeItemTypes": "Audio", "Filters": "IsPlayed",
            "SortBy": "PlayCount", "SortOrder": "Descending", "Limit": 10, "Fields": "UserData"})
        stats["topSongs"] = [{"itemId": i["Id"], "title": i.get("Name"),
                              "artist": ", ".join(x.get("Name", "") for x in i.get("ArtistItems") or []),
                              "album": i.get("Album"), "artId": i.get("AlbumId"), "artTag": i.get("AlbumPrimaryImageTag"),
                              "plays": (i.get("UserData") or {}).get("PlayCount", 0)}
                             for i in (r.json().get("Items", []) if r.ok else [])]
    return {**_public(account), "stats": stats, "moment": social.moment(uid), "nowPlaying": HUB.now_playing(uid),
            "favorites": favorites.json().get("TotalRecordCount", 0) if favorites.ok else 0,
            "library": social.library_size(account)["songs"]}


@router.get("/api/social/users/{user_id}")
async def social_user(user_id: str, a: Auth = Depends(auth)):
    account = accounts.user(user_id)
    if not account or (not account.get("visible", True) and account["id"] != a.user_id):
        raise HTTPException(404, "Unknown user")
    profile = await run_in_threadpool(_profile, account["id"], account)
    # A friend's songs the viewer has too: their own copy, to play it.
    for song in profile["stats"]["topSongs"] + profile["stats"]["recent"] + [profile.get("moment") or {}]:
        if song.get("itemId") and account["id"] != a.user_id:
            song["yourItemId"] = await run_in_threadpool(social.own_item, a.user_id, song["itemId"])
        elif song.get("itemId"):
            song["yourItemId"] = song["itemId"]
    return profile


@router.get("/api/social/track/{item_id}")
async def social_track(item_id: str, a: Auth = Depends(auth)):
    """Who else has this song (one of the viewer's), and who likes it."""
    return {"users": await run_in_threadpool(social.who_has, item_id, a.user_id, accounts.users())}


# ---------------------------------------------------------------------------
# Admin
# ---------------------------------------------------------------------------

class LoginBody(BaseModel):
    username: str
    password: str


@router.post("/api/admin/login")
def admin_login(body: LoginBody):
    """The admin page signs in with a Jellyfin administrator's account."""
    r = requests.post(f"{JELLYFIN_URL}/Users/AuthenticateByName", timeout=15, json={"Username": body.username, "Pw": body.password},
                      headers={"Authorization": 'MediaBrowser Client="Sonalex admin", Device="Web", DeviceId="sonalex-admin", Version="1.0"'})
    if r.status_code != 200:
        raise HTTPException(401, "Wrong username or password")
    data = r.json()
    if not (data["User"].get("Policy") or {}).get("IsAdministrator"):
        raise HTTPException(403, "Only the server's owner can open this page")
    return {"token": data["AccessToken"], "name": data["User"]["Name"]}


@router.get("/api/admin/requests")
def admin_requests(a: Auth = Depends(admin)):
    return {"requests": accounts.pending_requests()}


@router.post("/api/admin/requests/{request_id}/approve")
async def admin_approve(request_id: str, a: Auth = Depends(admin)):
    try:
        account = await run_in_threadpool(accounts.approve, request_id)
    except (accounts.AccountError, requests.HTTPError) as e:
        _error(e)
    if account.get("provider") == "deezer" and account.get("deezerId"):
        _sync_soon(account["slug"])  # their Deezer favorites start coming in at once
    return _public(account)


@router.post("/api/admin/requests/{request_id}/deny", status_code=204)
async def admin_deny(request_id: str, a: Auth = Depends(admin)):
    try:
        await run_in_threadpool(accounts.deny, request_id)
    except accounts.AccountError as e:
        _error(e)


@router.get("/api/admin/users")
async def admin_users(a: Auth = Depends(admin)):
    week, month = social.totals_since(7 * 86400), social.totals_since(30 * 86400)

    def collect():
        out = []
        for uid, account in accounts.users().items():
            out.append({**_public(account), **social.library_size(account), "visible": account.get("visible", True),
                        "weekMinutes": week.get(uid, 0), "monthMinutes": month.get(uid, 0),
                        "lastPlayed": social.last_played(uid), "nowPlaying": HUB.now_playing(uid),
                        "deezerName": account.get("deezerName"), "syncing": account["slug"] in _syncing})
        return out

    return {"users": await run_in_threadpool(collect)}


@router.get("/api/admin/users/{user_id}")
async def admin_user(user_id: str, a: Auth = Depends(admin)):
    account = accounts.user(user_id)
    if not account:
        raise HTTPException(404, "Unknown user")
    return await run_in_threadpool(_profile, account["id"], account)


@router.delete("/api/admin/users/{user_id}", status_code=204)
async def admin_remove(user_id: str, a: Auth = Depends(admin)):
    account = accounts.user(user_id)
    if account:
        _stop_sync(account["slug"])  # else it would go on filling a library that's gone
    try:
        await run_in_threadpool(accounts.remove, user_id)
    except accounts.AccountError as e:
        _error(e)


@router.post("/api/admin/users/{user_id}/sync", status_code=202)
def admin_sync(user_id: str, a: Auth = Depends(admin)):
    account = accounts.user(user_id)
    if not account or account.get("provider") not in ("spotify", "deezer"):
        raise HTTPException(400, "No music service connected for this user")
    _sync_soon(account["slug"])
    return {"queued": True}


@router.get("/api/admin/activity")
def admin_activity(a: Auth = Depends(admin)):
    names = {uid: acc["name"] for uid, acc in accounts.users().items()}
    return {"plays": [{**p, "user": names.get(p["userId"], "?")} for p in social.activity(60)]}


def _music_usage() -> dict:
    """Room the music really takes (each file once) and what sharing saves."""
    seen, real, logical = set(), 0, 0
    for account in accounts.users().values():
        root = Path(account["music"])
        for path in root.rglob("*") if root.exists() else []:
            try:
                st = path.stat()
            except OSError:
                continue
            if not path.is_file():
                continue
            logical += st.st_size
            if (st.st_dev, st.st_ino) not in seen:
                seen.add((st.st_dev, st.st_ino))
                real += st.st_size
    return {"realBytes": real, "logicalBytes": logical, "savedBytes": logical - real, "files": len(seen)}


def _read(path: str) -> str:
    try:
        return Path(path).read_text().strip()
    except OSError:
        return ""


@router.get("/api/admin/overview")
async def admin_overview(a: Auth = Depends(admin)):
    def collect():
        disk = shutil.disk_usage(DATA_DIR)
        mem = dict(line.split(":", 1) for line in _read("/proc/meminfo").splitlines() if ":" in line)
        kb = lambda k: int((mem.get(k) or "0 kB").split()[0]) * 1024  # noqa: E731
        temp = _read("/sys/class/thermal/thermal_zone0/temp")
        try:
            info = requests.get(f"{JELLYFIN_URL}/System/Info/Public", timeout=5).json()
        except (requests.RequestException, ValueError):
            info = {}
        cache = sum(f.stat().st_size for f in (DATA_DIR / "temp").rglob("*") if f.is_file()) if (DATA_DIR / "temp").exists() else 0
        return {
            "disk": {"total": disk.total, "used": disk.used, "free": disk.free},
            "music": _music_usage(), "cacheBytes": cache,
            "memory": {"total": kb("MemTotal"), "available": kb("MemAvailable")},
            "load": os.getloadavg(), "uptime": float((_read("/proc/uptime") or "0").split()[0]),
            "temperature": int(temp) / 1000 if temp.isdigit() else None,
            "jellyfin": {"name": info.get("ServerName"), "version": info.get("Version")},
            "modules": {"online": ONLINE, "spotifySync": SPOTIFY_SYNC, "signups": SIGNUPS,
                        "multiUser": accounts.multi_user_ready()},
            "users": len(accounts.users()), "pending": len(accounts.pending_requests()),
            "today": social.totals_since(86400),
        }

    return await run_in_threadpool(collect)


@router.get("/admin")
@router.get("/admin/")
def admin_page():
    return FileResponse(Path(__file__).parent / "admin.html", media_type="text/html")
