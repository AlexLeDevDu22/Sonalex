"""
lyrics.py – Find lyrics on LRCLIB (free, no key), as reliably as possible.

Tries, in order, until something is found:
  1. exact match with the duration (/api/get), the most precise;
  2. exact match without duration;
  3. the same with a cleaned title ("Song (feat. X) - Remastered" → "Song");
  4. a search (/api/search), keeping the best result by artist + title + duration.
Synced lyrics are preferred; plain lyrics are returned when that's all there is.
"""

import re
import time
import unicodedata

import requests

API = "https://lrclib.net/api"
HEADERS = {"User-Agent": "Sonalex/1.0 (https://github.com/AlexLeDevDu22/sonalex)"}


def _norm(text: str | None) -> str:
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(c for c in text if not unicodedata.combining(c)).lower()
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def clean_title(title: str) -> str:
    t = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", title or "")
    t = re.sub(r"\s+-\s+.*$", "", t)
    return t.strip() or (title or "")


def main_artist(artist: str) -> str:
    return re.split(r",| feat\.? | ft\.? | & | x ", artist or "", flags=re.I)[0].strip()


def _get(path: str, params: dict) -> dict | list | None:
    for attempt in range(3):
        try:
            r = requests.get(f"{API}{path}", params=params, headers=HEADERS, timeout=12)
        except requests.RequestException:
            time.sleep(1 + attempt)
            continue
        if r.status_code == 404:
            return None
        if r.status_code == 429:
            time.sleep(3 + attempt * 3)
            continue
        if r.ok:
            return r.json()
        return None
    return None


def _pick(data: dict | None) -> tuple[str | None, bool]:
    if not data or data.get("instrumental"):
        return None, False
    if data.get("syncedLyrics"):
        return data["syncedLyrics"], True
    if data.get("plainLyrics"):
        return data["plainLyrics"], False
    return None, False


def find_lyrics(title: str, artist: str, album: str | None = None, duration: float | None = None) -> tuple[str | None, bool]:
    """Returns (lyrics, synced). (None, False) when nothing is found."""
    artist1 = main_artist(artist)
    titles = list(dict.fromkeys([title, clean_title(title)]))
    best_plain: str | None = None

    for t in titles:
        attempts = []
        if duration:
            attempts.append({"track_name": t, "artist_name": artist1, "duration": round(duration)})
            if album:
                attempts.append({"track_name": t, "artist_name": artist1, "album_name": album, "duration": round(duration)})
        attempts.append({"track_name": t, "artist_name": artist1})
        for params in attempts:
            lyrics, synced = _pick(_get("/get", params))
            if lyrics and synced:
                return lyrics, True
            if lyrics and not best_plain:
                best_plain = lyrics

    # Search: best match by artist, title and duration.
    results = _get("/search", {"track_name": clean_title(title), "artist_name": artist1}) or []
    if not results:
        results = _get("/search", {"q": f"{artist1} {clean_title(title)}"}) or []
    wanted_t, wanted_a = _norm(clean_title(title)), _norm(artist1)
    scored = []
    for r in results if isinstance(results, list) else []:
        rt, ra = _norm(clean_title(r.get("trackName"))), _norm(r.get("artistName"))
        if not rt or not (wanted_t in rt or rt in wanted_t) or wanted_a not in ra:
            continue
        diff = abs((r.get("duration") or 0) - (duration or 0)) if duration else 0
        if duration and diff > 10:
            continue
        scored.append((0 if r.get("syncedLyrics") else 1, diff, r))
    for _, _, r in sorted(scored, key=lambda x: (x[0], x[1])):
        lyrics, synced = _pick(r)
        if lyrics:
            if synced:
                return lyrics, True
            best_plain = best_plain or lyrics
    return (best_plain, False) if best_plain else (None, False)


def save_lyrics_file(mp3_path: str, title: str, artist: str, album: str | None = None,
                     duration: float | None = None) -> str | None:
    """Writes <song>.lrc (synced) or <song>.txt (plain) next to the MP3 — Jellyfin reads both.
    Returns the written path, or None."""
    from pathlib import Path

    lyrics, synced = find_lyrics(title, artist, album, duration)
    if not lyrics:
        return None
    path = Path(mp3_path).with_suffix(".lrc" if synced else ".txt")
    path.write_text(lyrics, encoding="utf-8")
    return str(path)
