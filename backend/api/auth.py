"""
auth.py – Who's asking: the app's Jellyfin session is the key.

Jellyfin 12 no longer accepts the legacy X-Emby-Token header: always talk to it with
"Authorization: MediaBrowser … Token=…" (still accepted from the apps on the way in).
"""

import re

import requests
from fastapi import Depends, HTTPException, Request

from config import ONLINE, SPOTIFY_SYNC

from .common import JELLYFIN_URL, TTLCache

_tokens = TTLCache(ttl=600)
_admins = TTLCache(ttl=300)


class Auth:
    def __init__(self, token: str, user_id: str):
        self.token = token
        self.user_id = user_id.replace("-", "").lower()

    @property
    def headers(self) -> dict:
        return {"Authorization": f'MediaBrowser Client="Sonalex server", Device="Server", DeviceId="sonalex-server", '
                                 f'Version="1.0", Token="{self.token}"'}

    @property
    def account(self) -> dict | None:
        import accounts

        return accounts.user(self.user_id)

    @property
    def slug(self) -> str | None:
        account = self.account
        return account["slug"] if account else None


def _token_from(request: Request) -> str | None:
    header = request.headers.get("authorization", "")
    m = re.search(r'Token="([^"]+)"', header)
    if m:
        return m.group(1)
    if header.lower().startswith("bearer "):
        return header[7:].strip()
    return (request.headers.get("x-emby-token") or request.query_params.get("ApiKey")
            or request.query_params.get("api_key"))


def _user_for_token(token: str) -> str | None:
    """The Jellyfin user of a token; None if it isn't valid. Raises RequestException if Jellyfin
    can't be reached."""
    user_id = _tokens.get(token)
    if user_id:
        return user_id
    r = requests.get(f"{JELLYFIN_URL}/Users/Me", headers=Auth(token, "").headers, timeout=8)
    if r.status_code != 200:
        return None
    me = r.json()
    user_id = me["Id"]
    _tokens.set(token, user_id)
    _admins.set(token, bool((me.get("Policy") or {}).get("IsAdministrator")))
    return user_id


def auth(request: Request) -> Auth:
    token = _token_from(request)
    if not token:
        raise HTTPException(401, "Not signed in")
    try:
        user_id = _user_for_token(token)
    except requests.RequestException:
        raise HTTPException(503, "Jellyfin unreachable")
    if not user_id:
        raise HTTPException(401, "Invalid Jellyfin session")
    return Auth(token, user_id)


def admin(a: Auth = Depends(auth)) -> Auth:
    """A Jellyfin administrator (the server's owner)."""
    is_admin = _admins.get(a.token)
    if is_admin is None:
        _tokens.set(a.token, None)
        _user_for_token(a.token)
        is_admin = _admins.get(a.token)
    if not is_admin:
        raise HTTPException(403, "Only the server's owner can do that")
    return a


def online(a: Auth = Depends(auth)) -> Auth:
    """Routes of the online catalog: only when the server owner turned it on."""
    if not ONLINE:
        raise HTTPException(404, "The online catalog is off on this server")
    return a


def spotify_sync(a: Auth = Depends(auth)) -> Auth:
    if not SPOTIFY_SYNC:
        raise HTTPException(404, "The Spotify sync is off on this server")
    return a
