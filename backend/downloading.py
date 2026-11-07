import copy
import re
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unicodedata
import subprocess

from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError
from ytmusicapi import YTMusic

import local_song
from config import TEMP_ROOT
from song import Song
from utils.tag_mp3_metadata import add_metadata_to_mp3
from spotify import download_online_cover_image

ytmusic = YTMusic()


def normalize(text):
    if not text:
        return ""

    text = unicodedata.normalize("NFKD", text)
    text = "".join(
        c for c in text
        if not unicodedata.combining(c)
    )

    text = text.lower()

    text = re.sub(r"[^a-z0-9\s]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()

    return text


CLIP_WORDS = ("clip", "official video", "music video", "video officielle", "videoclip", "visualizer",
              "lyrics video", "lyric video", "paroles", "live", "extended", "sped up", "slowed", "8d")


def version_penalty(title: str, channel: str = "", wanted: str = "") -> float:
    """Clips, live, sped up…: other versions than the official audio (unless asked for).
    "Official audio", "audio" and YouTube's auto-generated "… - Topic" channels: the real song."""
    t, w = normalize(title), normalize(wanted)
    def has(text, word):
        return re.search(rf"\b{re.escape(word)}\b", text) is not None
    penalty = sum(8 for word in CLIP_WORDS if has(t, word) and not has(w, word))
    if has(t, "audio"):
        penalty -= 4
    if normalize(channel).endswith("topic"):
        penalty -= 6
    return penalty


def _base_title(text):
    """"Song (feat. X) - Remastered" → "song": what both sides call the same song."""
    text = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", text or "")
    text = re.sub(r"\s+-\s+.*$", "", text)
    return normalize(text)


def find_sources(song: Song) -> list[str]:
    """
    Sources possibles du son, de la plus sûre à la moins sûre (même logique que le streaming) :
      1. « songs » YouTube Music : titre compatible, artiste présent, durée à ±15 s ;
      2. vidéos YouTube Music : titre + durée ;
      3. recherche YouTube classique : titre + durée.
    Plusieurs candidats, parce qu'une vidéo trouvée peut avoir été supprimée.
    """
    wanted_title = _base_title(song.title)
    wanted_artists = [normalize(a) for a in [song.artist] + (song.featured_artists or []) if a]
    duration = (getattr(song, "duration_ms", None) or 0) / 1000
    query = f"{song.title} {song.artist}".strip()

    def ranked(results, need_artist, duration_key="duration_seconds", max_diff=15, artist_in_text=False):
        scored = []
        for r in results:
            vid = r.get("videoId") or r.get("id")
            rt = _base_title(r.get("title"))
            if not vid or not rt or not (wanted_title in rt or rt in wanted_title):
                continue
            # A remix instead of the original (unless a remix is what we want). Checked on the raw
            # title: _base_title drops "(… Remix)".
            if not want_remix and "remix" in normalize(r.get("title")):
                continue
            if need_artist:
                names = " ".join(normalize(a.get("name")) for a in r.get("artists") or [])
                if wanted_artists and not any(a in names for a in wanted_artists):
                    continue
            if artist_in_text:  # plain YouTube: no artist field, look in the title and the channel
                text = normalize(f"{r.get('title')} {r.get('channel') or r.get('uploader') or ''}")
                if wanted_artists and not any(a in text for a in wanted_artists):
                    continue
            d = r.get(duration_key) or 0
            if duration and not d and artist_in_text:
                continue
            diff = abs(d - duration) if d and duration else 5
            if diff > max_diff:
                continue
            channel = r.get("channel") or r.get("uploader") or " ".join(a.get("name", "") for a in r.get("artists") or [])
            score = -diff + (3 if rt == wanted_title else 0) - version_penalty(r.get("title"), channel, song.title)
            scored.append((score, vid))
        return [vid for _, vid in sorted(scored, reverse=True)]

    sources: list[str] = []
    want_remix = "remix" in normalize(song.title)
    for search_filter, limit, need_artist in (("songs", 12, True), ("videos", 8, False)):
        try:
            results = ytmusic.search(query, filter=search_filter, ignore_spelling=True)
        except Exception as e:
            print(f"Erreur recherche YouTube Music : {e}")
            results = []
        sources += [f"https://music.youtube.com/watch?v={v}" for v in ranked(results[:limit], need_artist)]
    try:
        with YoutubeDL({"quiet": True, "no_warnings": True, "extract_flat": True}) as ydl:
            found = ydl.extract_info(f"ytsearch8:{song.artist} {song.title} audio", download=False) or {}
        sources += [f"https://www.youtube.com/watch?v={v}"
                    for v in ranked(found.get("entries") or [], need_artist=False, duration_key="duration",
                                   max_diff=5, artist_in_text=True)]
    except Exception as e:
        print(f"Erreur recherche YouTube : {e}")
    return list(dict.fromkeys(sources))[:6]




def download_spotify(song: Song):
    """Fallback when YouTube Music has nothing: spotdl, run with this venv's Python, into a
    temp folder of its own (never "the first file lying in the temp folder")."""
    url = f"https://open.spotify.com/track/{song.spotify_id}"
    with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as tmp:
        res = subprocess.run(
            # No --download-deno (spotdl then asks "download it anyway? (y/N)" and stops without
            # downloading the song); stdin closed so it can never wait for an answer.
            [sys.executable, "-m", "spotdl", "download", url, "--output", tmp, "--format", "mp3"],
            capture_output=True, text=True, timeout=600, env=os.environ.copy(), stdin=subprocess.DEVNULL,
        )
        files = [f for f in os.listdir(tmp) if f.endswith(".mp3")]
        if res.returncode != 0 or not files:
            raise RuntimeError(f"spotdl failed for {song}: {(res.stderr or res.stdout)[-500:]}")
        shutil.move(os.path.join(tmp, files[0]), song.local_path)


def _download_covers(song: Song):
    for url, path in ((song.cover_url, song.cover_path), (song.artist_cover_url, song.artist_cover_path)):
        if url and path and not os.path.exists(path):
            try:
                download_online_cover_image(url, path)
            except Exception as e:
                print(f"Cover non téléchargée ({path}) : {e}")


def download_song(song: Song) -> str:
    """
    Télécharge une song depuis YouTube Music (ou Spotify en fallback),
    écrit les métadonnées, télécharge les covers et l'ajoute à local_song.

    Retourne le chemin local du fichier MP3.
    """
    # Vérifier si déjà téléchargé
    existing_path = local_song.song_already_downloaded(song.spotify_id)
    if existing_path:
        print(f"✅ {song.title}")
        return existing_path

    song.generate_local_path()

    # Already on the server, in a friend's library: the same file, linked (nothing downloaded).
    import library_index
    shared = library_index.find_file(key=song.spotify_id, isrc=song.isrc, title=song.title, artist=song.artist,
                                     duration_ms=song.duration_ms, exclude=song.local_path)
    if shared:
        library_index.link(shared, song.local_path)
        if os.path.exists(song.local_path):
            _download_covers(song)
            local_song.add_song(song)
            print(f"🔗 {song.artist} - {song.title} (déjà sur le serveur)")
            return song.local_path

    print(f"⬇ {song.artist} - {song.title}")

    album_dir = os.path.dirname(song.local_path)
    os.makedirs(album_dir, exist_ok=True)

    artist = song.artist or "No Artist"

    # ============================================================
    # 1. YOUTUBE MUSIC
    # ============================================================
    try:
        sources = find_sources(song)
    except Exception as e:
        print(f"Erreur recherche YouTube : {e}")
        sources = []
    # ============================================================
    # 2. FALLBACK SPOTIFY
    # ============================================================

    def via_spotdl():
        download_spotify(song)
        # Métadonnées + covers + ajout local
        add_metadata_to_mp3(song)
        _download_covers(song)
        local_song.add_song(song)
        return song.local_path

    if not sources:
        print(f"⚠️ Introuvable sur YouTube : {artist} - {song.title} → spotdl")
        return via_spotdl()

    # ============================================================
    # 3. TÉLÉCHARGEMENT yt-dlp
    # ============================================================

    # Downloaded and tagged in a temp folder, then moved in at once: Jellyfin must never index
    # a half-written MP3 without its tags.
    staging_dir = tempfile.mkdtemp(dir=TEMP_ROOT)
    staged = copy.copy(song)
    staged.local_path = os.path.join(staging_dir, "song.mp3")

    ydl_opts = {
        "format": "bestaudio/best",
        "outtmpl": os.path.join(staging_dir, "song"),
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "geo_bypass": True,
        "nocheckcertificate": True,
        "overwrites": True,
        "retries": 10,
        "fragment_retries": 10,
        "extractor_retries": 10,
        "socket_timeout": 30,
        "ignoreerrors": False,
        "postprocessors": [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "320",
            }
        ],
    }

    try:
        # First source that really downloads (a matching video may have been removed).
        last_error = None
        for url in sources:
            try:
                print(f"  ⬇ {url}")
                with YoutubeDL(ydl_opts) as ydl:
                    ydl.download([url])
                if os.path.exists(staged.local_path):
                    break
            except DownloadError as e:
                last_error = e
                print(f"    indisponible, source suivante")
        else:
            raise RuntimeError(f"aucune source YouTube utilisable ({last_error})")

        # 4. Métadonnées + paroles (sur la copie temporaire), puis déplacement dans la librairie
        add_metadata_to_mp3(staged)
        for ext in (".lrc", ".txt"):
            lyrics = Path(staged.local_path).with_suffix(ext)
            if lyrics.exists():
                shutil.move(str(lyrics), str(Path(song.local_path).with_suffix(ext)))
        shutil.move(staged.local_path, song.local_path)

        # 5. Covers (album + artiste)
        _download_covers(song)

        # 6. Ajout local
        local_song.add_song(song)

        print(f"✅ {song.title} - {song.artist} finally downloaded")

        return song.local_path

    except Exception as e:
        # yt-dlp failed (403, removed video…): last resort, spotdl.
        print(f"  yt-dlp a échoué ({e}) → spotdl")
        try:
            return via_spotdl()
        except Exception as e2:
            raise Exception(f"Impossible de télécharger : {song.artist} - {song.title} ({e2})") from e

    finally:
        shutil.rmtree(staging_dir, ignore_errors=True)
