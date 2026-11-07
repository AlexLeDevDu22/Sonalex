"""Song credits (producers, writers, engineers, label…) for the app's "Crédits" sheet.

Spotify's own credits endpoint is internal (it refuses our token: "RBAC: access denied"), so
they come from Genius, whose public site API has them, and is thorough for rap. Cached on disk
(misses retried after a week)."""

from __future__ import annotations

import time

import requests

from .common import JsonStore, base_title, normalize, song_signature

_UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"}
_store = JsonStore("credits.json")
_MISS_RETRY = 7 * 86400

# Genius' labels in French (others are kept as they are).
_ROLES = {
    "Producer": "Production", "Co-Producer": "Coproduction", "Additional Production": "Production additionnelle",
    "Executive Producer": "Production exécutive", "Vocal Producer": "Production vocale",
    "Composer": "Composition", "Lyricist": "Paroles", "Songwriter": "Écriture",
    "Mixing Engineer": "Mixage", "Mastering Engineer": "Mastering", "Recording Engineer": "Enregistrement",
    "Engineer": "Ingénieur du son", "Assistant Mixing Engineer": "Assistant mixage",
    "Label": "Label", "Distributor": "Distribution", "Publisher": "Édition",
    "Recorded At": "Enregistré à", "Mixed At": "Mixé à", "Mastered At": "Masterisé à",
    "Copyright ©": "Copyright ©", "Phonographic Copyright ℗": "Copyright ℗",
    "Guitar": "Guitare", "Bass": "Basse", "Drums": "Batterie", "Keyboards": "Claviers", "Piano": "Piano",
    "Programmer": "Programmation", "Background Vocals": "Chœurs", "Additional Vocals": "Voix additionnelles",
    "Sample": "Sample", "Video Director": "Réalisation du clip",
}
# Order of the sections in the sheet.
_ORDER = ["Interprété par", "Production", "Coproduction", "Production additionnelle", "Production exécutive",
          "Production vocale", "Écriture", "Paroles", "Composition", "Mixage", "Mastering", "Enregistrement"]


def _get(path: str, params: dict) -> dict:
    r = requests.get(f"https://genius.com/api{path}", params=params, headers=_UA, timeout=10)
    r.raise_for_status()
    return r.json().get("response") or {}


def _matches(hit: dict, title: str, artist: str) -> bool:
    want_t, want_a = base_title(title), normalize(artist)
    got_t = base_title(hit.get("title"))
    names = normalize(hit.get("artist_names") or (hit.get("primary_artist") or {}).get("name"))
    title_ok = got_t == want_t or (len(want_t) > 3 and (want_t in got_t or got_t in want_t))
    artist_ok = bool(want_a) and (want_a in names or normalize((hit.get("primary_artist") or {}).get("name")) in want_a)
    return title_ok and artist_ok


def _find_song_id(title: str, artist: str) -> int | None:
    for q in (f"{artist} {base_title(title)}", base_title(title)):
        hits = (_get("/search/song", {"q": q, "per_page": 10}).get("sections") or [{}])[0].get("hits") or []
        for h in hits:
            song = h.get("result") or {}
            if _matches(song, title, artist):
                return song.get("id")
    return None


def _person(a: dict) -> dict:
    image = a.get("image_url") or ""
    # Genius' default avatar isn't a photo.
    if "default_avatar" in image or "default_cover" in image:
        image = ""
    return {"name": a.get("name") or "", "image": image}


def _build(song: dict) -> dict:
    sections: dict[str, list[dict]] = {}

    def add(role: str, people: list[dict]):
        names = sections.setdefault(role, [])
        for p in people:
            if p.get("name") and all(p["name"] != n["name"] for n in names):
                names.append(_person(p))

    add("Interprété par", [song.get("primary_artist") or {}] + (song.get("featured_artists") or []))
    add("Production", song.get("producer_artists") or [])
    add("Écriture", song.get("writer_artists") or [])
    for c in song.get("custom_performances") or []:
        label = c.get("label") or ""
        add(_ROLES.get(label, label), c.get("artists") or [])
    ordered = sorted(sections.items(), key=lambda kv: _ORDER.index(kv[0]) if kv[0] in _ORDER else len(_ORDER))
    return {
        "found": True,
        "source": "Genius",
        "url": song.get("url"),
        "releaseDate": song.get("release_date_for_display"),
        "album": (song.get("album") or {}).get("name"),
        "sections": [{"role": role, "people": people} for role, people in ordered if people],
    }


def credits(title: str, artist: str) -> dict:
    key = song_signature(title, artist)
    hit = _store.get(key)
    if hit and (hit.get("found") or time.time() - hit.get("at", 0) < _MISS_RETRY):
        return hit
    song_id = _find_song_id(title, artist)
    if not song_id:
        result = {"found": False, "sections": [], "at": time.time()}
    else:
        result = _build(_get(f"/songs/{song_id}", {"text_format": "plain"}).get("song") or {})
    _store.set(key, result)
    return result
