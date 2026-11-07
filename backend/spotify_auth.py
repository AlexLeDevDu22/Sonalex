"""
spotify_auth.py – A user connects their Spotify account from the app.

The server's owner creates one Spotify app (developer.spotify.com, free) and puts its client id in
backend/.env (SPOTIFY_CLIENT_ID), with `sonalex://spotify-callback` as its redirect URI. The app
then signs the user in to Spotify (Authorization Code with PKCE: no secret on the phone), and hands
the code to the server, which keeps the user's token in their folder. Spotify's development mode
only lets in the accounts added to the app (dashboard → User Management): the owner adds his
friends' Spotify e-mails there.
"""

import json
import os
import time
from pathlib import Path

import requests

REDIRECT_URI = "sonalex://spotify-callback"
SCOPES = ("user-library-read user-library-modify playlist-read-private playlist-read-collaborative "
          "playlist-modify-public playlist-modify-private")


def client_id() -> str | None:
    return os.getenv("SPOTIFY_CLIENT_ID") or None


def connect(account: dict, code: str, verifier: str, redirect_uri: str = REDIRECT_URI) -> dict:
    """Exchanges the app's code for the user's tokens; returns {"id", "name"} of the Spotify account."""
    cid = client_id()
    if not cid:
        raise RuntimeError("Spotify isn't set up on this server (SPOTIFY_CLIENT_ID)")
    r = requests.post("https://accounts.spotify.com/api/token", timeout=20, data={
        "grant_type": "authorization_code", "code": code, "redirect_uri": redirect_uri,
        "client_id": cid, "code_verifier": verifier})
    if r.status_code != 200:
        raise RuntimeError(f"Spotify refused the sign-in: {r.text[:200]}")
    tokens = r.json()
    me = requests.get("https://api.spotify.com/v1/me", timeout=20,
                      headers={"Authorization": f"Bearer {tokens['access_token']}"})
    if me.status_code == 403:
        raise RuntimeError("This Spotify account isn't allowed in the server's Spotify app yet: "
                           "ask the server's owner to add your Spotify e-mail (User Management).")
    me.raise_for_status()
    profile = me.json()
    path = Path(account["spotifyToken"])
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps({"kind": "oauth", "client_id": cid, "access_token": tokens["access_token"],
                               "refresh_token": tokens["refresh_token"], "last_refreshed": time.time(),
                               "spotifyUser": profile["id"]}, indent=1), encoding="utf8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    return {"id": profile["id"], "name": profile.get("display_name") or profile["id"]}
