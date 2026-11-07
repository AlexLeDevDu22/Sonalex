"""
mixinfo.py – Musical analysis of a song for Mix transitions (numpy only).

For each file (decoded mono 11 kHz by ffmpeg):
  - tempo: autocorrelation of the onset envelope, 70–180 BPM with a mild prior around 110;
  - beats: dynamic-programming beat tracker (Ellis 2007, what librosa does), so beat times
    follow the music instead of a fixed grid;
  - downbeats: the beat phase (out of 4) with the strongest kick-band onsets;
  - key: chroma + Krumhansl-Schmuckler profiles, as a Camelot code (8A, 11B…) for harmonic mixing;
  - loudness of the loud part (dB), intro end and outro start (energy);
  - main part: the signal's own guess of where the voice is.

~3 s per song on the Pi. Cached by path + mtime in <data dir>/mixinfo.json.

with_voice() adds what isn't worth caching because it can change: the voice from the synced lyrics
(a new .lrc can arrive any night) and the sound's real edges in the file.
"""

import json
import os
import re
import subprocess
import threading
import time
from pathlib import Path

import numpy as np

from config import DATA_DIR

SR = 11025
HOP = 128
FPS = SR / HOP  # ~86 frames/s: 11.6 ms resolution
KEY_SR = 22050
VERSION = 7
CACHE = DATA_DIR / "mixinfo.json"
_lock = threading.Lock()
_cache: dict | None = None

MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
NOTE_NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]


def _read_disk() -> dict:
    try:
        return json.loads(CACHE.read_text())
    except (FileNotFoundError, ValueError):
        return {}


def _load_cache() -> dict:
    global _cache
    if _cache is None:
        _cache = _read_disk()
    return _cache


def decode(path: str, sr: int = SR) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
                         capture_output=True, check=True, timeout=180).stdout
    return np.frombuffer(raw, dtype=np.float32)


def _stft_mag(y: np.ndarray, n_fft: int, hop: int) -> np.ndarray:
    frames = (len(y) - n_fft) // hop
    win = np.hanning(n_fft).astype(np.float32)
    out = np.empty((frames, n_fft // 2 + 1), dtype=np.float32)
    for start in range(0, frames, 2048):  # chunks: bounded memory
        stop = min(frames, start + 2048)
        idx = np.arange(n_fft)[None, :] + (np.arange(start, stop)[:, None] * hop)
        out[start:stop] = np.abs(np.fft.rfft(y[idx] * win, axis=1))
    return out


def _tempo(onset: np.ndarray) -> float | None:
    env = onset - onset.mean()
    if len(env) < FPS * 20 or not env.any():
        return None
    n = 1 << (2 * len(env) - 1).bit_length()
    spec = np.fft.rfft(env, n)
    ac = np.fft.irfft(spec * np.conj(spec))[: len(env)]
    bpms = np.arange(70.0, 180.0, 0.25)
    lags = FPS * 60.0 / bpms
    grid = np.arange(len(ac))
    strength = np.interp(lags, grid, ac) + 0.5 * np.interp(lags * 2, grid, ac) + 0.25 * np.interp(lags * 4, grid, ac)
    strength = strength * np.exp(-0.5 * (np.log2(bpms / 110.0) / 0.9) ** 2)
    return float(bpms[int(np.argmax(strength))])


def _beat_track(onset: np.ndarray, bpm: float, tightness: float = 100.0) -> np.ndarray:
    """Ellis' dynamic programming: beats = onset peaks spaced close to the tempo's period."""
    period = FPS * 60.0 / bpm
    o = onset / (onset.std() + 1e-9)
    # Smooth a little around the beat so slightly early / late hits still count.
    kernel = np.exp(-0.5 * (np.arange(-int(period / 16) - 1, int(period / 16) + 2) / max(period / 32, 1)) ** 2)
    o = np.convolve(o, kernel / kernel.sum(), mode="same")
    lo, hi = max(1, int(round(period / 2))), int(round(period * 2))
    dts = np.arange(lo, hi + 1)
    penalty = -tightness * np.log(dts / period) ** 2
    n = len(o)
    score = o.copy()
    back = np.full(n, -1, dtype=np.int64)
    for t in range(lo, n):
        m = min(hi, t)
        cand = score[t - dts[: m - lo + 1]] + penalty[: m - lo + 1]
        k = int(np.argmax(cand))
        if cand[k] > 0:
            score[t] = o[t] + cand[k]
            back[t] = t - dts[k]
    tail = int(period)
    t = int(np.argmax(score[-tail:])) + n - tail
    beats = [t]
    while back[t] >= 0:
        t = int(back[t])
        beats.append(t)
    beats = np.array(beats[::-1], dtype=np.float64)
    # Drop beats in the silent edges.
    strong = o[beats.astype(int)] > 0.1 * np.median(o[beats.astype(int)])
    return beats[strong] / FPS


def _downbeat_phase(beats: np.ndarray, kick: np.ndarray) -> int:
    if len(beats) < 16:
        return 0
    idx = np.clip((beats * FPS).astype(int), 2, len(kick) - 3)
    strength = np.array([kick[i - 2:i + 3].max() for i in idx])
    return int(np.argmax([strength[p::4].mean() for p in range(4)]))


def _key(y: np.ndarray) -> dict:
    """Chroma (squared magnitude 55–2000 Hz, each frame normalized) vs Krumhansl profiles."""
    mag = _stft_mag(y, 8192, 4096) ** 2
    freqs = np.fft.rfftfreq(8192, 1 / KEY_SR)
    band = (freqs >= 55) & (freqs <= 2000)
    pcs = (np.round(12 * np.log2(freqs[band] / 440.0)).astype(int) + 9) % 12  # 0 = C
    m = mag[:, band]
    frames = np.zeros((len(m), 12))
    for p in range(12):
        frames[:, p] = m[:, pcs == p].sum(axis=1)
    chroma = (frames / (frames.sum(axis=1, keepdims=True) + 1e-9)).mean(axis=0)
    chroma = (chroma - chroma.mean()) / (chroma.std() + 1e-9)
    scores = []
    for tonic in range(12):
        for mode, profile in (("major", MAJOR), ("minor", MINOR)):
            scores.append((float(np.corrcoef(chroma, np.roll(profile, tonic))[0, 1]), tonic, mode))
    scores.sort(reverse=True)
    r, tonic, mode = scores[0]
    major_tonic = tonic if mode == "major" else (tonic + 3) % 12  # relative major
    camelot = (major_tonic * 7 % 12 + 7) % 12 + 1
    return {"name": NOTE_NAMES[tonic] + ("" if mode == "major" else "m"),
            "camelot": f"{camelot}{'B' if mode == 'major' else 'A'}",
            "confidence": round(r - scores[1][0], 3)}  # margin over the runner-up


def _refine(beats_frames: np.ndarray, o: np.ndarray) -> np.ndarray:
    """Sub-frame beat times: parabola through the onset peak around each tracked beat."""
    out = []
    for f in beats_frames.astype(int):
        lo, hi = max(1, f - 3), min(len(o) - 2, f + 3)
        k = lo + int(np.argmax(o[lo:hi + 1]))
        a, b, c = o[k - 1], o[k], o[k + 1]
        den = a - 2 * b + c
        out.append(k + (0.5 * (a - c) / den if den < 0 else 0.0))
    return np.array(out) / FPS


def _local_grid(o: np.ndarray, kick: np.ndarray, period: float, start: float, end: float) -> dict | None:
    """A perfectly regular beat grid for [start, end] s: the phase that puts the beats on the onsets,
    the downbeat (1 of 4) with the strongest kicks, and how clearly rhythmic that part is."""
    f0, f1 = int(max(0, start) * FPS), int(min(end * FPS, len(o) - 1))
    if f1 - f0 < 8 * period * FPS:
        return None
    grid = np.arange(len(o))
    best = (-1.0, 0.0, period * FPS)
    # Tempo can drift a little over a song: refine period and phase together, for this part only.
    for P in period * FPS * np.linspace(0.985, 1.015, 31):
        for phase in np.arange(0, P, 0.5):
            score = float(np.interp(np.arange(f0 + phase, f1, P), grid, o).mean())
            if score > best[0]:
                best = (score, phase, P)
    # Finer phase around the winner.
    P = best[2]
    for phase in np.arange(best[1] - 0.5, best[1] + 0.5, 0.05):
        score = float(np.interp(np.arange(f0 + phase, f1, P), grid, o).mean())
        if score > best[0]:
            best = (score, phase, P)
    period = P / FPS
    pos = np.arange(f0 + best[1], f1, P)
    kicks = np.interp(pos, grid, kick)
    down = int(np.argmax([kicks[q::4].mean() for q in range(4)])) if len(pos) >= 8 else 0
    strength = best[0] / (float(o[f0:f1].mean()) + 1e-9)
    return {"downbeat": round(float(pos[down]) / FPS, 4), "period": round(period, 5), "strength": round(strength, 2)}


def _main_part(path: str, bpm: float) -> tuple[float, float] | None:
    """Where the song's main part (verses, hook — the voice) starts and ends, in seconds.
    Loop-based music repeats bar after bar: the median over neighbouring bars of the centred
    250–3500 Hz spectrum is the repeating backing; what doesn't repeat (the voice, a melody that
    comes in) is the foreground (REPET, Rafii & Pardo). Main part = foreground clearly present."""
    try:
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"],
                             capture_output=True, check=True, timeout=180).stdout
    except Exception:
        return None
    st = np.frombuffer(raw, np.float32).reshape(-1, 2)
    if len(st) < SR * 20:
        return None
    hop = 256
    mid, side = (st[:, 0] + st[:, 1]) * 0.5, (st[:, 0] - st[:, 1]) * 0.5
    freqs = np.fft.rfftfreq(1024, 1 / SR)
    band = (freqs >= 250) & (freqs <= 3500)
    centre = np.maximum(_stft_mag(mid, 1024, hop)[:, band] - _stft_mag(side, 1024, hop)[:, band], 0)
    fps = SR / hop
    bar = int(round(4 * 60 / bpm * fps))
    n = len(centre)
    idx = np.arange(n)
    backing = np.median(np.stack([centre[np.clip(idx + k * bar, 0, n - 1)] for k in (-4, -3, -2, -1, 1, 2, 3, 4)]),
                        axis=0)
    fg = np.maximum(centre - backing, 0).sum(axis=1)
    sec = int(n / fps)
    per_s = np.array([fg[int(i * fps):int((i + 1) * fps)].mean() for i in range(sec)])
    per_s = np.convolve(per_s, np.ones(2) / 2, mode="same") / (np.median(per_s) + 1e-9)
    present = np.where(per_s >= 0.75)[0]
    if not len(present):
        return None
    return float(present[0]), float(present[-1] + 1)


def _fit_period(beats: np.ndarray) -> float:
    """Tempo from all beats: least squares of beat time vs beat number (robust to a skipped beat)."""
    d = np.diff(beats)
    m = float(np.median(d))
    index = np.concatenate([[0], np.cumsum(np.maximum(1, np.round(d / m)))])
    return float(np.polyfit(index, beats, 1)[0])


def analyze(path: str) -> dict | None:
    try:
        hi = decode(path, KEY_SR)
    except Exception:
        return None
    if len(hi) < KEY_SR * 20:
        return None
    y = (hi[0::2][: len(hi) // 2] + hi[1::2][: len(hi) // 2]) * 0.5  # 11 kHz for rhythm
    duration = len(y) / SR
    mag = _stft_mag(y, 1024, HOP)
    logmag = np.log1p(mag)
    flux = np.maximum(np.diff(logmag, axis=0), 0)
    onset = np.concatenate([[0], flux.sum(axis=1)])
    freqs = np.fft.rfftfreq(1024, 1 / SR)
    kick = np.concatenate([[0], flux[:, (freqs >= 40) & (freqs <= 150)].sum(axis=1)])

    bpm = _tempo(onset)
    if not bpm:
        return None
    beats = _beat_track(onset, bpm)
    o = np.convolve(onset / (onset.std() + 1e-9), np.ones(3) / 3, mode="same")
    k = np.convolve(kick / (kick.std() + 1e-9), np.ones(3) / 3, mode="same")
    beats = _refine(beats * FPS, o)
    period = _fit_period(beats) if len(beats) > 16 else 60.0 / bpm
    bpm = round(60.0 / period, 2)
    phase = _downbeat_phase(beats, kick)

    sec = int(duration)
    rms = np.sqrt(np.array([np.mean(y[i * SR:(i + 1) * SR] ** 2) for i in range(sec)]) + 1e-12)
    smooth = np.convolve(rms, np.ones(3) / 3, mode="same")
    level = float(np.median(smooth))
    loud = np.where(smooth >= 0.55 * level)[0]
    intro_end = float(loud[0]) if len(loud) else 0.0
    outro_start = float(loud[-1] + 1) if len(loud) else duration - 12
    # Where the music really ends: after it, only near-silence / the last echo of a fade.
    audible = np.where(smooth >= 0.12 * level)[0]
    music_end = float(min(duration, audible[-1] + 1)) if len(audible) else duration
    loudness = float(20 * np.log10(np.mean(smooth[smooth >= level]) + 1e-9))

    main = _main_part(path, bpm) or (intro_end, outro_start)
    return {
        "v": VERSION,
        # The main part (where the voice is): transitions stay out of it.
        "mainStart": round(main[0], 1),
        "mainEnd": round(min(main[1], music_end), 1),
        "bpm": bpm,
        "duration": round(duration, 3),
        "beats": [round(float(b), 3) for b in beats],
        "downbeatPhase": phase,
        # Regular grids where transitions happen: the start, and the end of the song.
        "intro": _local_grid(o, k, period, 0, 45),
        "outro": _local_grid(o, k, period, duration - 80, duration),
        "tonality": _key(hi),
        "loudness": round(loudness, 2),
        "introEnd": round(intro_end, 1),
        "outroStart": round(min(max(outro_start, music_end - 45), music_end - 4), 1),
        "musicEnd": round(music_end, 2),
    }


def info_for_path(path: str) -> dict | None:
    """Cached analysis. The API and the nightly / batch analysis are separate processes writing
    the same file: on a miss re-read it, and write by merging under a file lock (else one
    process overwrites what the other just computed)."""
    global _cache
    try:
        st = os.stat(path)
    except OSError:
        return None
    # By file, not by path: the same song linked into several users' libraries is one file.
    key = f"inode:{st.st_dev}:{st.st_ino}|{st.st_mtime_ns}"
    legacy = f"{path}|{st.st_mtime_ns}"  # analyses made before, by path
    with _lock:
        cache = _load_cache()
        hit = cache.get(key) or cache.get(legacy)
        if not (hit and hit.get("v") == VERSION):
            _cache = _read_disk()
            hit = _cache.get(key) or _cache.get(legacy)
        if hit and hit.get("v") == VERSION:
            return None if hit.get("unusable") else hit
    result = analyze(path)
    import fcntl
    with _lock, open(str(CACHE) + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache = _read_disk()
        # A file that can't be analysed (too short…) isn't tried again every time it comes up.
        cache[key] = result or {"v": VERSION, "unusable": True}
        tmp = CACHE.with_suffix(".tmp")
        tmp.write_text(json.dumps(cache))
        tmp.replace(CACHE)
        _cache = cache
    return result


# ---------------------------------------------------------------------------
# Where the voice is (Mix transitions must stay out of it)
# ---------------------------------------------------------------------------

_LRC_TIME = re.compile(r"\[(\d+):(\d+(?:[.:]\d+)?)\]")
_online_lyrics: dict[str, dict] = {}
_sound_cache: dict[str, tuple[float, float]] = {}


def lyric_span(lrc: str, duration: float) -> tuple[float, float] | None:
    """(first word, end of the last line) of synced lyrics; None if they don't fit this file."""
    stamps = []
    for raw in lrc.splitlines():
        text = _LRC_TIME.sub("", raw).strip()
        for m, s in _LRC_TIME.findall(raw):
            stamps.append((int(m) * 60 + float(s.replace(":", ".")), any(c.isalpha() for c in text)))
    stamps.sort()
    sung = [t for t, has_words in stamps if has_words]
    if len(sung) < 4 or sung[-1] > duration + 1:
        return None
    last = sung[-1]
    # An empty last stamp often marks the real end; else a line lasts about as long as the others.
    gaps = sorted(b - a for a, b in zip(sung, sung[1:]) if b - a < 12)
    line = min(gaps[len(gaps) // 2], 6.0) if gaps else 4.0
    closing = next((t for t, has_words in stamps if t > last and not has_words), None)
    end = min(closing, last + 8.0) if closing is not None else last + line
    return sung[0], end + 0.5


def _lyrics_of_online(key: str) -> str | None:
    """Synced lyrics of a streamed song (no .lrc next to its file). Never holds a plan for long:
    what isn't there after a few seconds counts as unknown, and is ready for the next plans."""
    entry = _online_lyrics.get(key)
    if entry is None:
        if len(_online_lyrics) > 2000:
            _online_lyrics.clear()
        entry = _online_lyrics[key] = {"text": None, "done": threading.Event()}

        def fetch():
            try:
                from . import catalog
                text, synced = catalog.find_lyrics_of(key)
                entry["text"] = text if synced else None
            except Exception as e:
                print(f"[mixinfo] paroles de {key}: {e!r}"[:200], flush=True)
            finally:
                entry["done"].set()

        threading.Thread(target=fetch, daemon=True).start()
    entry["done"].wait(4)
    return entry["text"]


def _sound_edges(path: str, duration: float) -> tuple[float, float]:
    """Where the sound really starts (at most 3 s in) and ends (searched in the last 30 s) in the
    file: two songs can join there, without the files' silences between them."""
    if path not in _sound_cache:
        def loud(args: list[str]):
            raw = subprocess.run(["ffmpeg", "-v", "error", *args, "-i", path, "-ac", "1", "-ar", str(SR),
                                  "-f", "f32le", "-"], capture_output=True, check=True, timeout=30).stdout
            return np.flatnonzero(np.abs(np.frombuffer(raw, np.float32)) > 0.005)  # -46 dB

        try:
            head, tail = loud(["-t", "3.2"]), loud(["-sseof", "-30"])
            start = float(head[0]) / SR if len(head) else 3.0
            end = duration - 30 + (float(tail[-1]) / SR if len(tail) else 0.0)
            _sound_cache[path] = (round(min(start, 3.0), 3), round(min(end, duration), 3))
        except Exception:
            _sound_cache[path] = (0.0, duration)
    return _sound_cache[path]


def with_voice(info: dict, path: str, key: str | None = None) -> dict:
    """The analysis + voiceStart / voiceEnd / soundStart. From the synced lyrics when there are
    some (what the listener follows: 87 % of the library); else a cautious guess, because the
    signal alone misses hooks that repeat identically (they look like backing)."""
    lrc = None
    try:
        lrc = Path(path).with_suffix(".lrc").read_text(errors="replace")
    except OSError:
        if key and key.startswith(("sp:", "dz:")):
            lrc = _lyrics_of_online(key)
    span = lyric_span(lrc, info["duration"]) if lrc else None
    main_start, main_end = info.get("mainStart") or 0.0, info.get("mainEnd") or info["duration"]
    music_end = info.get("musicEnd") or info["duration"]
    if span:
        # Ad-libs and hooks past the last written line: the signal may see them, within reason.
        voice_start, voice_end = span[0], max(span[1], min(main_end, span[1] + 10))
    else:
        voice_start, voice_end = min(main_start, 8.0), max(main_end, music_end - 8.0)
    sound_start, sound_end = _sound_edges(path, info["duration"])
    return {**info, "voiceStart": round(voice_start, 2), "voiceEnd": round(min(voice_end, info["duration"] - 0.05), 2),
            "voiceKnown": bool(span), "soundStart": sound_start, "soundEnd": sound_end}


def path_for_key(key: str, wait: bool = False) -> str | None:
    """App key → file on the Pi: 'sp:<id>' (downloaded, or streamed), 'dz:<id>' (streamed) or a
    Jellyfin item id.
    `wait`: for an online song, wait for (or start) its download."""
    if key.startswith(("sp:", "dz:")):
        import library_index

        local = library_index.find_key(key)  # someone on the server has it
        if local:
            return local
        from .streamer import STREAMER

        job = STREAMER.jobs.get(key)
        if job and job.done and job.path.exists():
            job.last_access = time.time()  # about to be mixed: not for the cleaning
            return str(job.path)
        if wait:
            try:
                return str(STREAMER.wait_done(key, timeout=120).path)
            except Exception:
                return None
        return None
    import jellyfin

    from config import JELLYFIN_API_KEY

    params = {"Ids": key, "Fields": "Path"}
    if not JELLYFIN_API_KEY:  # a user session only sees with its user; an API key sees every library
        params["UserId"] = jellyfin.USER_ID
    r = jellyfin._get(f"{jellyfin.SERVER}/Items", raise_for_status=False, params=params)
    items = r.json().get("Items", []) if r.ok else []
    return items[0].get("Path") if items else None
