"""
streamer.py – Plays any online song within seconds.

For a track key ("sp:…" / "dz:…") a Job:
  1. finds the song on YouTube Music (duration-checked), falling back to plain YouTube;
  2. asks yt-dlp for the direct audio URL (AAC/m4a, exact size known);
  3. downloads it in ranged chunks into a temporary file — small first chunk so playback
     starts right away, then 1 MB chunks (far faster than real time);
  4. meanwhile the app's HTTP range requests are served from that growing file.

Temporary files are removed after a few hours unless the song gets saved to the library.
"""

import asyncio
import subprocess
import threading
import time
from pathlib import Path

import requests
from fastapi import HTTPException
from fastapi.responses import Response, StreamingResponse

from . import catalog
from .common import TEMP_DIR, base_title, normalize, parse_range

FIRST_CHUNK = 256 * 1024
CHUNK = 1024 * 1024
TEMP_TTL = 3 * 3600
TEMP_MAX_BYTES = 2 * 1024 ** 3


class Job:
    def __init__(self, key: str):
        self.key = key
        self.meta: dict | None = None
        self.state = "pending"  # pending → resolving → downloading → done | failed
        self.error: str | None = None
        self.path: Path = TEMP_DIR / f"{key.replace(':', '_')}.m4a"
        self.size: int | None = None
        self.written = 0
        self.content_type = "audio/mp4"
        self.created = time.time()
        self.last_access = time.time()
        self.finished = threading.Event()

    @property
    def done(self) -> bool:
        return self.state == "done"


class Streamer:
    def __init__(self):
        self.jobs: dict[str, Job] = {}
        self._lock = threading.Lock()
        self._resolve_slots = threading.Semaphore(3)
        self._ytm = None
        self._ytm_lock = threading.Lock()
        threading.Thread(target=self._janitor, daemon=True).start()

    def warm_up(self):
        """Load yt-dlp and YouTube Music once at startup so the first song starts faster."""
        try:
            import yt_dlp  # noqa: F401
            with self._ytm_lock:
                self._ytmusic()
        except Exception as e:
            print("[streamer] warm-up failed:", e)

    # -- Public -------------------------------------------------------------

    def job(self, key: str) -> Job:
        """Returns the job for `key`, starting it if needed (or retrying a failed one)."""
        with self._lock:
            job = self.jobs.get(key)
            if job and job.state == "failed" and time.time() - job.created > 30:
                job = None
            if job and job.done and not job.path.exists():
                job = None
            if job is None:
                job = Job(key)
                self.jobs[key] = job
                threading.Thread(target=self._run, args=(job,), daemon=True).start()
            job.last_access = time.time()
            return job

    def wait_done(self, key: str, timeout: float = 180) -> Job:
        job = self.job(key)
        job.finished.wait(timeout)
        if not job.done:
            raise RuntimeError(job.error or "Download failed")
        return job

    async def serve(self, key: str, range_header: str | None, head: bool = False) -> Response:
        job = self.job(key)
        start_wait = time.time()
        while job.size is None and job.state != "failed":
            if time.time() - start_wait > 60:
                break
            await asyncio.sleep(0.05)
        if job.size is None:
            raise HTTPException(502, job.error or "Can’t play this song")

        size = job.size
        byte_range = parse_range(range_header, size)
        if byte_range is None:
            return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
        start, end = byte_range

        headers = {
            "Accept-Ranges": "bytes",
            "Content-Length": str(end - start + 1),
            "Cache-Control": "no-store",
        }
        status = 200
        if range_header:
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
            status = 206
        if head:
            return Response(status_code=status, headers=headers, media_type=job.content_type)

        async def body():
            pos = start
            with open(job.path, "rb") as f:
                f.seek(start)
                while pos <= end:
                    job.last_access = time.time()
                    available = job.written
                    if available > pos:
                        chunk = f.read(min(min(available, end + 1) - pos, 65536))
                        if chunk:
                            pos += len(chunk)
                            yield chunk
                            continue
                    if job.done or job.state == "failed":
                        # The file came out shorter than announced (or the download died): finish the
                        # response with silence-free padding instead of leaving the player hanging.
                        if pos <= end:
                            yield bytes(end + 1 - pos)
                        return
                    await asyncio.sleep(0.04)

        return StreamingResponse(body(), status_code=status, headers=headers, media_type=job.content_type)

    def status(self, key: str) -> dict:
        job = self.jobs.get(key)
        if not job:
            return {"state": "none"}
        return {"state": job.state, "error": job.error, "size": job.size, "written": job.written}

    # -- Pipeline ---------------------------------------------------------

    def _run(self, job: Job):
        try:
            with self._resolve_slots:
                job.state = "resolving"
                job.meta = catalog.track_meta(job.key)
                source = self._find_youtube(job.meta)
                info = self._extract(source)
            if info.get("ext") == "m4a" and info.get("url") and info.get("filesize"):
                self._download_ranged(job, info, source)
            else:
                self._download_transcoded(job, source)
            job.state = "done"
        except Exception as e:
            print(f"[streamer] {job.key} failed:", e)
            job.error = "This song can’t be found online." if isinstance(e, LookupError) else "Can’t play this song."
            job.state = "failed"
        finally:
            job.finished.set()

    def _ytmusic(self):
        if self._ytm is None:
            from ytmusicapi import YTMusic
            self._ytm = YTMusic()
        return self._ytm

    def _find_youtube(self, meta: dict) -> str:
        title = meta["title"]
        artists = [a["name"] for a in meta.get("artists", [])]
        wanted_title = base_title(title)
        wanted_artists = [normalize(a) for a in artists if a]
        duration = (meta.get("durationMs") or 0) / 1000
        want_remix = "remix" in normalize(title)

        def pick(results, need_artist: bool):
            best, best_score = None, -1e9
            for r in results:
                vid = r.get("videoId")
                if not vid:
                    continue
                rt = base_title(r.get("title"))
                if not rt or not (wanted_title in rt or rt in wanted_title):
                    continue
                # Never a remix in place of the original (unless the song is a remix).
                if not want_remix and "remix" in normalize(r.get("title")):
                    continue
                names = " ".join(normalize(a.get("name")) for a in r.get("artists") or [])
                if need_artist and wanted_artists and not any(a and a in names for a in wanted_artists):
                    continue
                d = r.get("duration_seconds") or 0
                diff = abs(d - duration) if d and duration else 5
                if diff > 15:
                    continue
                from downloading import version_penalty
                channel = " ".join(a.get("name", "") for a in r.get("artists") or [])
                score = -diff + (3 if rt == wanted_title else 0) - version_penalty(r.get("title"), channel, title)
                if score > best_score:
                    best, best_score = vid, score
            return best

        query = f"{title} {artists[0] if artists else ''}".strip()
        with self._ytm_lock:
            try:
                songs = self._ytmusic().search(query, filter="songs", ignore_spelling=True)
            except Exception:
                songs = []
        vid = pick(songs[:12], need_artist=True)
        if not vid:
            with self._ytm_lock:
                try:
                    videos = self._ytmusic().search(query, filter="videos", ignore_spelling=True)
                except Exception:
                    videos = []
            vid = pick(videos[:8], need_artist=False)
        if vid:
            return f"https://music.youtube.com/watch?v={vid}"
        return f"ytsearch1:{artists[0] if artists else ''} - {title} audio"

    @staticmethod
    def _extract(source: str) -> dict:
        from yt_dlp import YoutubeDL

        opts = {"quiet": True, "no_warnings": True, "noplaylist": True, "socket_timeout": 15,
                "format": "140/bestaudio[ext=m4a]/bestaudio"}
        with YoutubeDL(opts) as ydl:
            info = ydl.extract_info(source, download=False)
        if info and info.get("entries"):
            entries = [e for e in info["entries"] if e]
            if not entries:
                raise LookupError("no result")
            info = entries[0]
        if not info:
            raise LookupError("no result")
        return info

    def _download_ranged(self, job: Job, info: dict, source: str):
        url = info["url"]
        size = int(info["filesize"])
        headers = dict(info.get("http_headers") or {})
        refreshes = 0
        session = requests.Session()
        job.path.parent.mkdir(parents=True, exist_ok=True)
        with open(job.path, "wb") as f:
            job.content_type = "audio/mp4"
            job.size = size
            job.state = "downloading"
            pos = 0
            while pos < size:
                end = min(pos + (FIRST_CHUNK if pos == 0 else CHUNK) - 1, size - 1)
                data = None
                for attempt in range(4):
                    try:
                        r = session.get(url, headers={**headers, "Range": f"bytes={pos}-{end}"}, timeout=20)
                        if r.status_code in (200, 206) and r.content:
                            data = r.content
                            if r.status_code == 200:  # no range support: whole file at once
                                data = data[pos:]
                            break
                    except requests.RequestException:
                        pass
                    time.sleep(0.5 * (attempt + 1))
                if data is None and refreshes < 2:
                    # YouTube's link may have expired or been cut: get a fresh one and resume here.
                    refreshes += 1
                    fresh = self._extract(source)
                    if int(fresh.get("filesize") or 0) == size and fresh.get("url"):
                        url, headers = fresh["url"], dict(fresh.get("http_headers") or {})
                        continue
                if data is None:
                    print(f"[streamer] {job.key}: download interrupted at {pos}/{size}")
                    raise RuntimeError("download interrupted")
                f.write(data)
                f.flush()
                pos += len(data)
                job.written = pos
        job.size = job.written

    def _download_transcoded(self, job: Job, source: str):
        """Rare formats (no m4a): fetch with yt-dlp, convert to AAC, then serve the whole file."""
        from yt_dlp import YoutubeDL

        job.state = "downloading"
        raw = TEMP_DIR / f"{job.key.replace(':', '_')}.src"
        with YoutubeDL({"quiet": True, "no_warnings": True, "noplaylist": True, "format": "bestaudio/best",
                        "outtmpl": str(raw) + ".%(ext)s"}) as ydl:
            info = ydl.extract_info(source, download=True)
            if info and info.get("entries"):
                info = info["entries"][0]
            src = Path(ydl.prepare_filename(info))
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vn", "-c:a", "aac", "-b:a", "192k",
                        "-movflags", "+faststart", str(job.path)], check=True, timeout=600)
        src.unlink(missing_ok=True)
        job.written = job.path.stat().st_size
        job.size = job.written

    # -- Housekeeping -----------------------------------------------------

    def _janitor(self):
        for f in TEMP_DIR.glob("*"):
            if f.is_file():
                f.unlink(missing_ok=True)
        while True:
            time.sleep(600)
            now = time.time()
            with self._lock:
                for key, job in list(self.jobs.items()):
                    if now - job.last_access > TEMP_TTL and job.state in ("done", "failed"):
                        job.path.unlink(missing_ok=True)
                        del self.jobs[key]
                # Size cap: drop the least recently used finished files.
                total = sum(j.size or 0 for j in self.jobs.values())
                for job in sorted(self.jobs.values(), key=lambda j: j.last_access):
                    if total <= TEMP_MAX_BYTES:
                        break
                    if job.done and now - job.last_access > 600:
                        job.path.unlink(missing_ok=True)
                        total -= job.size or 0
                        del self.jobs[job.key]


STREAMER = Streamer()

