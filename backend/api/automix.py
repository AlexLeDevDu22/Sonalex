"""
automix.py – DJ-style Mix, rendered on the Pi as gapless *segments*.

In Mix mode the app plays, back to back on one AVAudioPlayerNode, one segment per song:

    segment(X) = [transition from the previous song W into X]  +  X  until X's own cut

A segment ends exactly where the next one starts (same decoder, same processing state), so the
app's sample-accurate scheduling gives a continuous stream: no gap, no click, ever.

The two rules every transition W → X obeys, whatever its style:
  - X never starts before W's voice is over (the end of its synced lyrics, see mixinfo.with_voice);
  - W is gone when X's voice starts.

Styles, by what the two songs allow (mixinfo.py gives tempo, beat grids, key, loudness, voice):
  1. *glide*: tempos within 8 % (or half / double time). W's tempo slides to X's over 16 or 8 beats
     (rubberband, pitch kept; over the voice only if the change is too small to hear), then one of
     W's downbeats lands exactly on X's first downbeat and they blend in time: X's highs come in,
     basslines swap on a downbeat, W's highs fade. Ideally W's natural end meets X's first word, so
     nothing is cut. X is never stretched (its time, lyrics and progress stay exact). Keys that
     clash get a shorter blend.
  2. *echo*: tempos too far apart: never two beats out of time. A filter takes W's bass then drums
     away once its voice is over, W stops on a downbeat, its last two beats ring out in echoes while
     X starts underneath.
  3. *join*: no rhythm to work with: W to the end of its music, X's first sound right after, without
     the silences of the two files in between.
Levels matched (W only ever turned down), a lookahead limiter on the sum, Apple Lossless output (no
encoder delay / overshoot).

Seamless joins: every render starts 2 s before its first sample (pre-roll) so the limiter and the
filters are in the same state as at the end of the previous segment, then trims the pre-roll.
"""

import hashlib
import json
import subprocess
import threading
import time
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import mixinfo
from .common import TEMP_DIR

MIX_DIR = TEMP_DIR.parent / "mix"  # not inside the streamer's folder: it empties it at start
MIX_DIR.mkdir(parents=True, exist_ok=True)
VERSION = "seg10"
CROSSOVER_HZ = 180
MAX_GLIDE = 0.08  # beyond, the stretch is heard
MAX_GLIDE_ON_VOICE = 0.025  # a voice may only be stretched this little
MAX_OVERLAP = 20.0  # seconds both songs can be heard at most
MAX_OVERLAP_CLASH = 10.0  # the same when their keys don't go together
MIN_STRENGTH = 1.35  # how clearly the grid sits on the beats (1 = no rhythm found)
PREROLL = 2.0
SR_OUT = 44100

FMT = "aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo"
LIMITER = "alimiter=limit=0.98:attack=5:release=200:level=disabled:latency=1"
# Zero-phase FIR low band (realigned sample-exactly: the filter starts its output 50 ms early).
LOWS = (f"firequalizer=gain='if(lt(f,{CROSSOVER_HZ}),0,-200)':delay=0.05:zero_phase=on:accuracy=2,"
        "atrim=start_sample=2205,asetpts=N/SR/TB")

_pool = ThreadPoolExecutor(max_workers=1)  # one render at a time: the Pi also streams
_jobs: dict[str, dict] = {}
_plans: OrderedDict[tuple[str, str], dict | None] = OrderedDict()
_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Planning
# ---------------------------------------------------------------------------

def _camelot(code: str | None):
    if not code or len(code) < 2:
        return None
    return int(code[:-1]), code[-1]


def harmonic(a: dict, b: dict) -> bool:
    """Camelot wheel: same code, ±1 with the same letter, or the relative major / minor."""
    ka, kb = _camelot((a.get("tonality") or {}).get("camelot")), _camelot((b.get("tonality") or {}).get("camelot"))
    if not ka or not kb:
        return False
    (na, la), (nb, lb) = ka, kb
    return (na - nb) % 12 in (0, 1, 11) if la == lb else na == nb


def _first_downbeat(grid: dict) -> float:
    bar = 4 * grid["period"]
    d = grid["downbeat"] % bar
    return d + bar if d < 0.05 else d


def _plan_glide(w: dict, x: dict, end_w: float, min_cut: float) -> dict | None:
    """Beat-matched blend. X's first sample lands on W's beats once the tempo has glided; among
    W's downbeats after its voice, the one where W's end best meets X's first word."""
    out, intro = w["outro"], x["intro"]
    ta, tb = out["period"], intro["period"]
    bar_a, bar_x = 4 * ta, 4 * tb
    # Speed of W at the end of the glide so its beats fall on X's (or on every other one).
    r, k = min(((ta / (tb * m), m) for m in (0.5, 1.0, 2.0)), key=lambda c: abs(c[0] - 1))
    change = abs(r - 1)
    if change > MAX_GLIDE:
        return None
    db0 = _first_downbeat(intro)
    voice_w, voice_x = w["voiceEnd"], x["voiceStart"]
    clash = not harmonic(w, x)
    target = min(voice_x, MAX_OVERLAP_CLASH if clash else MAX_OVERLAP)
    best = None
    for glide in ((16 * ta, 8 * ta) if change > 0.004 else (0.0,)):
        j = int((end_w - out["downbeat"]) // bar_a)
        while True:
            t_m = out["downbeat"] + j * bar_a  # W's downbeat X's first downbeat lands on
            j -= 1
            x_in = t_m - db0 * r  # W's time when X's first sample plays
            left = (end_w - x_in) / r  # how long W still has to play from there
            if x_in < voice_w or left > 90:
                break
            cut = x_in - glide * (1 + r) / 2
            overlap = min(left, target)
            # A real blend or nothing: not worth bending W's tempo for a couple of seconds.
            if t_m > end_w - ta or overlap < (2 if change > MAX_GLIDE_ON_VOICE else 1) * bar_x or cut < min_cut:
                continue
            if change > MAX_GLIDE_ON_VOICE and cut < voice_w:
                continue
            bars_left = round((end_w - t_m) / bar_a)
            # Nothing of W wasted, as much blend as X's intro gives, on a phrase of W when possible.
            score = (left - overlap) + 0.5 * (target - overlap) - (bar_a / 2 if bars_left % 4 == 0 else 0)
            if best is None or score < best[0]:
                best = (score, glide, cut, t_m, left)
        if best:
            break  # the longer glide is the smoother one: the shorter only if it's the only way
    if not best:
        return None
    _, glide, cut, t_m, left = best
    x_start = glide
    tau_d = x_start + db0
    tau_w = x_start + left
    # W fully gone when X's voice starts, and at most the overlap together.
    gone = min(tau_w, x_start + voice_x, x_start + (MAX_OVERLAP_CLASH if clash else MAX_OVERLAP))
    # Basslines swap on one of X's downbeats, halfway through the blend.
    swap = tau_d + max(0, round(((gone - tau_d) / 2) / bar_x)) * bar_x
    swap = max(min(swap, gone - tb), x_start + tb)
    return {
        "style": "glide", "cut": round(cut, 4), "rate": round(r, 6), "glide": round(glide, 4),
        "tauD": round(tau_d, 4), "tauE": round(gone, 4), "tauW": round(tau_w, 4),
        "xStart": round(x_start, 4), "swap": round(swap, 4), "beatX": round(tb, 5),
        "gainW": _match_gain(w, x), "multiple": k, "beats": round((end_w - t_m) / ta), "harmonic": not clash,
        "bpmW": round(60 / ta, 1), "bpmX": round(60 / tb, 1),
    }


def _plan_echo(w: dict, x: dict, end_w: float, min_cut: float) -> dict | None:
    """W stops on a downbeat after its voice (its last one, W plays on as long as it can) and rings
    out in echoes while X starts: the tempos never have to meet."""
    out = w["outro"]
    ta = out["period"]
    bar = 4 * ta
    voice_w, voice_x = w["voiceEnd"], x["voiceStart"]
    lead = min(x.get("soundStart") or 0.0, voice_x)
    # The voice sings up to the very end: W isn't stopped at all, the echoes follow its last note.
    stop = out["downbeat"] + int((end_w - out["downbeat"]) // bar) * bar
    if stop < voice_w:
        stop = end_w
    # The filter sweep, only once the voice is over; at least one bar, or it's just a lurch.
    sweep_from = max(voice_w, stop - 3 * bar)
    sweep = stop - sweep_from >= bar
    # X opening on its voice: a breath for the echoes first.
    breath = max(0.0, ta - (voice_x - lead))
    cut = min(sweep_from if sweep else stop - ta, stop - lead - 0.5)
    if cut < min_cut:
        return None
    x_start = stop - cut + breath - lead
    tail = 2 * bar  # the echoes: 3 repeats of W's last 2 beats
    return {
        "style": "echo", "cut": round(cut, 4), "beatW": round(ta, 5), "barW": round(bar, 4),
        "stop": round(stop - cut, 4), "sweep": round(stop - cut if sweep else 0.0, 4),
        "xStart": round(x_start, 4), "xVoice": round(voice_x, 3), "xDown": round(_first_downbeat(x["intro"]), 4) if x.get("intro") else 0.0,
        "tauE": round(min(stop - cut + tail, x_start + voice_x), 4),
        "bpmW": round(60 / ta, 1), "bpmX": round(60 / x["intro"]["period"], 1) if x.get("intro") else None,
    }


def _plan_join(w: dict, x: dict, end_w: float) -> dict | None:
    """No rhythm to work with: W to the end of its music, X's first sound right after. None when
    the files already end and start on sound: plain back-to-back is exactly that."""
    lead = x.get("soundStart") or 0.0
    # To the last sound of W: without rhythm, a quiet ending is the song's ending, not an outro.
    end = max(end_w, min(w.get("soundEnd") or w["duration"], w["duration"] - 0.05))
    if w["duration"] - end < 0.5 and lead < 0.2:
        return None
    cut = max(0.0, end - lead - 1.0)
    return {
        "style": "join", "cut": round(cut, 4), "stop": round(end - cut, 4),
        "xStart": round(end - cut - lead, 4), "tauE": round(end - cut + 0.4, 4),
    }


def _match_gain(w: dict, x: dict) -> float:
    return round(max(-6.0, min(0.0, (x.get("loudness") or 0) - (w.get("loudness") or 0))), 2)


def transition(w: dict, x: dict) -> dict | None:
    """How W hands over to X; None = plain back-to-back. Takes mixinfo.with_voice()'s analyses.
    Times: W's own time for `cut`, the output (segment) time τ for the rest, τ = 0 at `cut`."""
    duration = w["duration"]
    # W's end: where its music really ends (not the file's silent last seconds), voice included.
    end_w = min(duration - 0.05, max(w.get("musicEnd") or duration, w["voiceEnd"]))
    min_cut = max(30.0, duration * 0.4)
    out, intro = w.get("outro"), x.get("intro")
    if out and out["strength"] >= MIN_STRENGTH:
        plan = None
        if intro and intro["strength"] >= MIN_STRENGTH:
            plan = _plan_glide(w, x, end_w, min_cut)
        plan = plan or _plan_echo(w, x, end_w, min_cut)
        if plan:
            return plan
    return _plan_join(w, x, end_w)


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _split(src: str, low: str, high: str) -> str:
    """Two bands that sum back to the input sample for sample: highs = input − lows."""
    return (f"[{src}]asplit=2[{src}x][{src}y];[{src}x]{LOWS},asplit=2[{low}][{src}l];"
            f"[{src}y][{src}l]amerge=inputs=2,pan=stereo|c0=c0-c2|c1=c1-c3[{high}]")


def _gain_ramp(db: float, start: float, length: float = 4.0) -> str:
    """W's level eased from unchanged (as at the end of its previous segment) to matched, over a few
    seconds: an instant step at the join would be heard."""
    g = 10 ** (db / 20)
    return f"volume=volume='1-({1 - g:.5f})*clip((t-{start:.4f})/{length},0,1)':eval=frame"


def _sweep_commands(start: float, length: float) -> str:
    """High-pass rising from 20 Hz to ~1.2 kHz over `length` s (exponential, like a DJ filter knob)."""
    cmds = []
    steps = max(2, int(length / 0.05))
    for i in range(steps + 1):
        f = 20 * (60 ** (i / steps))
        cmds.append(f"{start + length * i / steps:.4f} highpass@hp f {f:.1f}")
    return ";".join(cmds)


def _glide_commands(t: dict, offset: float) -> str:
    """rubberband tempo over the glide: smooth ramp 1 → r, as commands on W's input time."""
    r, g = t["rate"], t["glide"]
    cmds = ["0.0 rubberband@rw tempo 1.0"]
    if g > 0:
        steps = max(2, int(g / 0.05))
        for i in range(1, steps + 1):
            tau = g * i / steps
            speed = 1 + (r - 1) * tau / g
            t_in = offset + tau + (r - 1) * tau * tau / (2 * g)
            cmds.append(f"{t_in:.4f} rubberband@rw tempo {speed:.6f}")
    else:
        cmds.append(f"{offset:.4f} rubberband@rw tempo {r:.6f}")
    return ";".join(cmds)


def _decode_mono(path: Path | str, seconds: float | None = None):
    import numpy as np
    from .mixinfo import SR

    limit = ["-t", f"{seconds:.3f}"] if seconds else []
    return np.frombuffer(subprocess.run(["ffmpeg", "-v", "error", *limit, "-i", str(path), "-ac", "1", "-ar", str(SR),
                                         "-f", "f32le", "-"], capture_output=True, check=True, timeout=180).stdout,
                         np.float32)


def _onsets(wav: Path):
    import numpy as np
    from .mixinfo import FPS, HOP, SR, _stft_mag

    y = _decode_mono(wav)
    mag = _stft_mag(y, 1024, HOP)
    on = np.concatenate([[0], np.maximum(np.diff(np.log1p(mag), axis=0), 0).sum(axis=1)])
    return np.convolve(on / (on.std() + 1e-9), np.ones(3) / 3, mode="same"), FPS, len(y) / SR


def _rhythm_bands(y):
    """Onsets of the kick and of the snare / body of the sound: what makes two songs sound in time
    or not (hi-hats dominate a full-band measure, and they often sit between the beats)."""
    import numpy as np
    from .mixinfo import HOP, SR, _stft_mag

    mag = np.log1p(_stft_mag(y, 1024, HOP))
    freqs = np.fft.rfftfreq(1024, 1 / SR)
    bands = []
    for lo, hi in ((30, 150), (150, 2500)):
        flux = np.maximum(np.diff(mag[:, (freqs >= lo) & (freqs < hi)], axis=0), 0).sum(axis=1)
        bands.append(np.convolve(np.concatenate([[0], flux]), np.ones(3) / 3, mode="same"))
    return bands


def _beat_offset(wav_w: Path, path_x: str, x_start: float, end: float, period: float) -> float | None:
    """How far X must move (seconds, always later) for its rhythm to fall on W's, from what is
    really heard in the blend [x_start, end] (render time) rather than from the two beat grids: a
    grid can sit half a beat off (on the off-beats), which would make the blend a trainwreck.
    None when the blend is too short, or when no position is clearly better than the planned one."""
    import numpy as np
    from .mixinfo import FPS

    span = end - x_start
    if span < 4 * period:
        return None
    bands_w = _rhythm_bands(_decode_mono(wav_w))
    bands_x = _rhythm_bands(_decode_mono(path_x, span + 2 * period))
    f0, n, frames = int(x_start * FPS), int(span * FPS), int(round(period * FPS))
    # The lag is only known modulo the beat, and X can only move later.
    scores = np.zeros(frames)
    for bw, bx in zip(bands_w, bands_x):
        w = bw[f0:f0 + n] - bw[f0:f0 + n].mean()
        for lag in range(frames):
            # X moved `lag` later: frame i of W is heard with frame i − lag of X.
            seg_w, seg_x = w[lag:], bx[:len(w) - lag]
            seg_x = seg_x - seg_x.mean()
            scores[lag] += float((seg_w * seg_x).sum() / (np.linalg.norm(seg_w) * np.linalg.norm(seg_x) + 1e-9))
    best = int(np.argmax(scores))
    if best == 0 or scores[best] - scores[0] < 0.15 or scores[best] < 0.2:
        return None
    return best / FPS


def _measure_grid(on, fps: float, lo: float, hi: float, period: float) -> tuple[float, float]:
    """(period, phase) in seconds of the beats really heard in [lo, hi] of a render."""
    import numpy as np

    grid = np.arange(len(on))
    f0, f1 = lo * fps, min(hi * fps, len(on) - 1)
    best = (-1.0, 0.0, period * fps)
    for P in period * fps * np.linspace(0.99, 1.01, 41):
        for ph in np.arange(0, P, 0.25):
            score = float(np.interp(np.arange(f0 + ph, f1, P), grid, on).mean())
            if score > best[0]:
                best = (score, ph, P)
    _, ph, P = best
    for fine in np.arange(ph - 0.3, ph + 0.3, 0.02):
        score = float(np.interp(np.arange(f0 + fine, f1, P), grid, on).mean())
        if score > best[0]:
            best = (score, fine, P)
    return best[2] / fps, (f0 + best[1]) / fps


def _w_source(t: dict, pw: float) -> str:
    """W from exactly `pw` before its cut, sample-exact (decoded from the start: no seek rounding,
    so it lines up to the sample with the previous segment's end)."""
    first = round(t["cut"] * SR_OUT) - round(pw * SR_OUT)
    return f"[0:a]{FMT},atrim=start_sample={first},asetpts=N/SR/TB"


def _render_w_glide(path_w: str, t: dict, pw: float, wav: Path):
    """W alone: original during the pre-roll, cross-fading (equal power, 300 ms) into the
    stretched, gliding W."""
    graph = ";".join([
        f"{_w_source(t, pw)},{_gain_ramp(t['gainW'], pw + max(0.0, t['xStart'] - 4.0))},"
        f"atrim=end={t.get('tauW', t['tauE']) * t['rate'] + pw + 1:.4f},"
        "asplit=2[wo][wr]",
        f"[wo]atrim=end={pw + 0.4:.4f},afade=t=out:st={pw + 0.05:.4f}:d=0.3:curve=qsin[wo2]",
        f"[wr]asendcmd=c='{_glide_commands(t, pw)}',"
        "rubberband@rw=tempo=1.0:transients=crisp:pitchq=quality:channels=together,"
        f"afade=t=in:st={pw + 0.05:.4f}:d=0.3:curve=qsin[wr2]",
        "[wo2][wr2]amix=inputs=2:normalize=0:duration=longest[out]",
    ])
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path_w, "-filter_complex", graph, "-map", "[out]",
                    "-c:a", "pcm_f32le", str(wav)], check=True, capture_output=True, timeout=600)


def align_glide(path_w: str, path_x: str, t: dict, target_period: float, pw: float, wav: Path) -> dict:
    """Renders W's glide, measures where its beats really fall (time-stretchers drift and lag by
    tens of ms) and returns the transition with X placed on them: tempo corrected once if needed,
    X's start shifted onto W's real downbeat, W's real end."""
    t = dict(t)
    for attempt in range(2):
        _render_w_glide(path_w, t, pw, wav)
        on, fps, length = _onsets(wav)
        lo = pw + t["glide"] + 0.5
        hi = min(pw + t.get("tauW", t["tauE"]) - 1.0, lo + 48 * target_period)
        period, phase = _measure_grid(on, fps, lo, hi, target_period)
        drift = float(period / target_period - 1)
        measurable = hi - lo >= 8 * target_period  # less than that says nothing about the tempo
        if measurable and abs(drift) > 0.0015 and attempt == 0:
            t["rate"] = round(t["rate"] * (1 + drift), 6)  # W a bit too slow / fast: once more
            continue
        break
    d = t["tauD"] + pw
    beat = phase + round((d - phase) / period) * period  # W's real beat closest to the plan
    shift = beat - d
    # Too short to measure, or a measure that makes no sense (the stretcher only lags by tens of ms):
    # the plan is better than a wrong correction, which would put the beats out of time.
    if not measurable or abs(shift) > 0.12:
        shift = 0.0
    shift = float(shift)
    w_end = float(length - pw)  # where W's audio really ends (segment time)
    # Then what the ear checks: do the two rhythms really fall together?
    offset = _beat_offset(wav, path_x, t["xStart"] + shift + pw, min(t["tauE"] + shift + pw, length), target_period) or 0.0
    # What remains of the blend must stay one: else keep the plan, the blend is short anyway.
    if t["xStart"] + shift + offset + 2 * t["beatX"] > min(t["tauE"] + shift + offset, w_end):
        offset = 0.0
    move = shift + offset
    gone = min(t["tauE"] + move, w_end)
    t.update({"tauD": round(t["tauD"] + move, 4), "xStart": round(t["xStart"] + move, 4),
              "swap": round(max(min(t["swap"] + move, gone - t["beatX"]), t["xStart"] + move + t["beatX"]), 4),
              "tauE": round(gone, 4),
              "measured": {"shiftMs": round(shift * 1000, 1), "driftPct": round(drift * 100, 3),
                           "offsetMs": round(offset * 1000, 1)}})
    return t


def _echo_graph(t: dict, pw: float) -> list[str]:
    """W up to its stop (`[W]`), under a filter sweep if there's room, plus the echoes after it:
    its last 2 beats repeating on the beat, without bass, fading out."""
    bar, beat = t["barW"], t["beatW"]
    stop = t["stop"] + pw  # render time
    src_from = stop - 2 * beat
    source = f"{_w_source(t, pw)},atrim=end={stop + beat + 0.1:.4f},asplit=2[wd][we]"
    if t["sweep"]:
        # The filter only after the cut: before it, W must be sample-identical to the end of its
        # previous segment (even a 20 Hz high-pass shifts the bass phase: a click).
        source = (f"{_w_source(t, pw)},atrim=end={stop + beat + 0.1:.4f},asplit=2[wraw][wsw];"
                  f"[wraw]atrim=end={pw + 0.6:.4f},afade=t=out:st={pw + 0.05:.4f}:d=0.5[wraw2];"
                  f"[wsw]asendcmd=c='{_sweep_commands(pw, t['sweep'])}',highpass@hp=f=20:p=2,"
                  f"afade=t=in:st={pw + 0.05:.4f}:d=0.5[wsw2];"
                  "[wraw2][wsw2]amix=inputs=2:normalize=0:duration=longest,asplit=2[wd][we]")
    ms = beat * 2000
    return [
        source,
        f"[wd]afade=t=out:st={stop:.4f}:d={beat * 0.75:.4f}:curve=qsin[wdry]",
        # aecho hears only the source (in_gain ≈ 0): its repeats start exactly at the stop.
        f"[we]atrim=start={src_from:.4f}:end={stop:.4f},asetpts=PTS-STARTPTS,"
        "afade=t=in:d=0.005,"
        f"afade=t=out:st={2 * beat - 0.005:.4f}:d=0.005,apad=pad_dur={2 * bar + 2 * beat:.4f},"
        f"aecho=in_gain=0.001:out_gain=1:delays={ms:.1f}|{2 * ms:.1f}|{3 * ms:.1f}:decays=0.55|0.32|0.18,"
        f"highpass=f=250,lowpass=f=7000,afade=t=out:st={2 * beat + bar:.4f}:d={bar:.4f}:curve=qsin,"
        f"adelay=delays={round(src_from * SR_OUT)}S:all=1[wecho]",
        "[wdry][wecho]amix=inputs=2:normalize=0:duration=longest[W]",
    ]


def render_segment(path_x: str, path_w: str | None, t: dict | None, x_from: float, x_to: float, out: Path):
    """Segment = [transition from W (if any)] + X from `x_from` to `x_to` (X's time).
    Every boundary is an exact sample number, so consecutive segments join sample for sample."""
    parts, inputs = [], []
    x_end = round(x_to * SR_OUT)  # X's sample where this segment ends
    if t:
        t = dict(t)
        # Output (segment) time τ: 0 at W's cut; the render starts `pw` earlier (pre-roll).
        pw = min(PREROLL, t["cut"])
        pws = round(pw * SR_OUT)
        if t["style"] == "glide":
            # W pre-rendered and measured; input 0 is that render (starts at τ = −pw).
            wav = out.with_suffix(".w.wav")
            t.update(align_glide(path_w, path_x, t, t["beatX"] * t.get("multiple", 1.0), pw, wav))
            inputs += ["-i", str(wav), "-i", path_x]
            parts += ["[0:a]anull[W]"]
        else:
            inputs += ["-i", path_w, "-i", path_x]
        delay = round((t["xStart"] + pw) * SR_OUT)  # X's first sample, in render samples
        t["xStart"] = round(delay / SR_OUT - pw, 6)
        x_start = t["xStart"]
        x_in = x_start + pw
        if t["style"] == "glide":
            swap, beat = t["swap"] + pw, t["beatX"]
            # Equal-power blend of the highs; the basses swap in half a beat, X's whole on the downbeat.
            w_from = x_in + (swap - x_in) / 2
            w_high = f"afade=t=out:st={w_from:.4f}:d={max(0.5, t['tauE'] + pw - w_from):.4f}:curve=qsin"
            x_high = f"afade=t=in:st={x_in:.4f}:d={max(beat, swap - x_in):.4f}:curve=qsin"
            w_low = f"afade=t=out:st={swap - beat / 2:.4f}:d={beat / 2:.4f}:curve=hsin"
            x_low = f"afade=t=in:st={swap - beat / 2:.4f}:d={beat / 2:.4f}:curve=hsin"
        else:
            w_high = w_low = "anull"
            if t["style"] == "echo":
                parts += _echo_graph(t, pw)
                beat = t["beatW"]
                # X opens quickly (it may sing at once), its bass on its first downbeat.
                x_high = f"afade=t=in:st={x_in:.4f}:d={min(beat, max(0.05, t['xVoice'] * 0.8)):.4f}:curve=qsin"
                x_low = f"afade=t=in:st={x_in + max(0.0, t['xDown'] - beat / 2):.4f}:d={beat / 2:.4f}:curve=hsin"
            else:  # join
                stop = t["stop"] + pw
                parts += [f"{_w_source(t, pw)},afade=t=out:st={stop - 0.4:.4f}:d=0.4:curve=qsin,atrim=end={stop + 0.1:.4f}[W]"]
                x_high = x_low = f"afade=t=in:st={x_in:.4f}:d=0.02"
        # W silent by tauE whatever happens (short blends: X's voice comes in).
        fade = min(2 * (t.get("beatX") or t.get("beatW") or 0.2), max(0.2, t["tauE"] - max(0.0, t["xStart"])))
        parts += [
            f"[W]afade=t=out:st={t['tauE'] + pw - fade:.4f}:d={fade:.4f}:curve=qsin[Wf]",
            _split("Wf", "Wl", "Wh"),
            f"[Wl]{w_low}[wl]",
            f"[Wh]{w_high}[wh]",
            f"[1:a]{FMT},atrim=end_sample={x_end},adelay=delays={delay}S:all=1[X]",
            _split("X", "Xl", "Xh"),
            f"[Xl]{x_low}[xl]",
            f"[Xh]{x_high}[xh]",
            f"[xh][xl][wl][wh]amix=inputs=4:normalize=0:duration=first:dropout_transition=0,{LIMITER},"
            f"atrim=start_sample={pws}:end_sample={delay + x_end},asetpts=N/SR/TB,"
            "aresample=osf=s16p:dither_method=triangular[out]",
        ]
    else:
        first = round(x_from * SR_OUT)
        pre = min(round(PREROLL * SR_OUT), first)
        inputs += ["-i", path_x]
        parts += [f"[0:a]{FMT},atrim=start_sample={first - pre}:end_sample={x_end},asetpts=N/SR/TB,{LIMITER},"
                  f"atrim=start_sample={pre},asetpts=N/SR/TB,aresample=osf=s16p:dither_method=triangular[out]"]
    tmp = out.with_suffix(".part.m4a")
    subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(parts),
                    "-map", "[out]", "-c:a", "alac", "-movflags", "+faststart", str(tmp)],
                   check=True, capture_output=True, timeout=600)
    tmp.replace(out)
    out.with_suffix(".w.wav").unlink(missing_ok=True)
    return t


# ---------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------

def _janitor():
    cutoff = time.time() - 6 * 3600
    for f in MIX_DIR.iterdir():  # segments, their plans, what a failed render left
        if f.stat().st_mtime < cutoff:
            f.unlink(missing_ok=True)
    with _lock:
        for seg_id in [s for s, job in _jobs.items() if job["done"].is_set() and not job["path"].exists()]:
            del _jobs[seg_id]


def _info(key: str | None, wait: bool):
    if not key:
        return None, None
    path = mixinfo.path_for_key(key, wait=wait)
    info = mixinfo.info_for_path(path) if path else None
    return (path, mixinfo.with_voice(info, path, key)) if info else (None, None)


def _plan(path_w: str, info_w: dict, path_x: str, info_x: dict) -> dict | None:
    """One plan per pair: W's segment ends at the cut the next one starts from, so it mustn't
    change in between (lyrics that just arrived, an upgraded .lrc…)."""
    pair = (path_w, path_x)
    with _lock:
        if pair in _plans:
            _plans.move_to_end(pair)
            return _plans[pair]
    plan = transition(info_w, info_x)
    with _lock:
        plan = _plans.setdefault(pair, plan)
        while len(_plans) > 500:
            _plans.popitem(last=False)
    return plan


def segment(key: str, prev: str | None = None, nxt: str | None = None, start: float = 0.0,
            until: float | None = None) -> dict:
    """Plans X's segment (transition in from `prev`, X until its cut towards `nxt`) and renders it
    in the background. With `prev`, the segment starts at prev's cut (the app must have played
    prev's segment up to there). Without, X from `start`."""
    path_x, info_x = _info(key, wait=True)
    if not info_x:
        return {"ok": False, "reason": "song not available on the server yet"}
    path_w, info_w = _info(prev, wait=False) if prev else (None, None)
    t_in = _plan(path_w, info_w, path_x, info_x) if info_w else None
    path_y, info_y = _info(nxt, wait=False) if nxt else (None, None)
    t_out = _plan(path_x, info_x, path_y, info_y) if info_y else None
    if t_out and not t_in and start >= t_out["cut"] - 1:
        t_out = None  # already past where the transition would start: X just plays to its end

    x_dur = info_x["duration"]
    cut = t_out["cut"] if t_out else x_dur  # where X hands over to the next song
    x_to = min(cut, until) if until else cut  # pieces: shorter files, so playback starts fast
    x_from = 0.0 if t_in else max(0.0, min(start, x_to - 1))
    sig = f"{VERSION}|{path_x}|{path_w if t_in else ''}|{x_from:.3f}|{x_to:.3f}|{t_in}"
    seg_id = hashlib.sha1(sig.encode()).hexdigest()[:20]
    out = MIX_DIR / f"{seg_id}.m4a"

    with _lock:
        job = _jobs.get(seg_id)
        if job and job["done"].is_set() and (job["error"] or not out.exists()):
            # Failed, or its file was cleaned up since (6 h old): render it again.
            job = None
        if not job:
            job = {"path": out, "done": threading.Event(), "error": None, "t": t_in}
            _jobs[seg_id] = job
            if out.exists():
                job["done"].set()
                # Measured at render time: the beat alignment moved X.
                try:
                    job["t"] = json.loads(out.with_suffix(".json").read_text())
                except (OSError, ValueError):
                    pass
            else:
                def run():
                    try:
                        _janitor()
                        started = time.time()
                        job["t"] = render_segment(path_x, path_w, t_in, x_from, x_to, out) or t_in
                        if job["t"]:
                            out.with_suffix(".json").write_text(json.dumps(job["t"]))
                        kind = (f"{t_in['style']} depuis {Path(path_w).stem} {(job['t'] or {}).get('measured', '')}"
                                if t_in else "sans transition")
                        print(f"[automix] segment {Path(path_x).stem} ({kind}), jusqu'à {x_to:.1f}s, "
                              f"rendu en {time.time() - started:.1f}s", flush=True)
                    except subprocess.CalledProcessError as e:
                        job["error"] = (e.stderr or b"")[-400:].decode(errors="replace")
                        print(f"[automix] échec {seg_id}: {job['error']}", flush=True)
                    except Exception as e:
                        job["error"] = repr(e)[:300]
                        print(f"[automix] échec {seg_id}: {job['error']}", flush=True)
                    finally:
                        job["done"].set()
                _pool.submit(run)

    return {
        "ok": True, "id": seg_id, "url": f"/api/mix/stream/{seg_id}",
        # X's time = segment time − xStart (before xStart: the previous song still playing alone).
        "xStart": t_in["xStart"] if t_in else -x_from,
        # Segment time until which the previous song is still heard (artwork animation).
        "outgoingUntil": t_in["tauE"] if t_in else 0.0,
        # X's time where this segment ends (its cut towards the next song, or its end).
        "endsAt": round(x_to, 4), "cut": round(cut, 4), "duration": round(x_dur, 3),
        "transitionIn": t_in, "transitionOut": t_out,
    }


def segment_meta(seg_id: str) -> dict:
    """Where the song really starts in a rendered segment (after the beat alignment)."""
    t = (_jobs.get(seg_id) or {}).get("t")
    return {"xStart": t["xStart"], "outgoingUntil": t["tauE"]} if t else {}


def wait_file(seg_id: str, timeout: float = 180) -> Path | None:
    job = _jobs.get(seg_id)
    if job:
        job["done"].wait(timeout)
        path = job["path"] if job["path"].exists() and not job["error"] else None
    else:
        path = MIX_DIR / f"{seg_id}.m4a"
        path = path if path.exists() else None
    if path:
        path.touch()  # in use: the janitor only removes what hasn't been played for 6 h
        if path.with_suffix(".json").exists():
            path.with_suffix(".json").touch()
    return path
