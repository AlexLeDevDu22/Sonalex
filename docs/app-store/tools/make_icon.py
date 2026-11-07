"""Draws the Sonalex icon (1024×1024, opaque, as the App Store wants it).

    backend/.venv/bin/python docs/app-store/tools/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[3]
OUT = [ROOT / "ios/Sonalex/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
       ROOT / "ios/Sonalex/Resources/Assets.xcassets/Logo.imageset/logo.png",
       ROOT / "docs/app-store/icon-1024.png"]
S = 4096  # drawn big, scaled down: smooth edges

TOP_LEFT, BOTTOM_RIGHT = (176, 120, 255), (64, 40, 200)  # lilac → deep violet, top to bottom
MIDDLE = (124, 92, 255)  # the app's accent


def gradient() -> Image.Image:
    img = Image.new("RGB", (S, S))
    px = img.load()
    small = Image.new("RGB", (256, 256))
    sp = small.load()
    for y in range(256):
        for x in range(256):
            t = (x * 0.25 + y) / (255 * 1.25)
            a, b, u = (TOP_LEFT, MIDDLE, t / 0.55) if t < 0.55 else (MIDDLE, BOTTOM_RIGHT, (t - 0.55) / 0.45)
            sp[x, y] = tuple(round(a[i] + (b[i] - a[i]) * u) for i in range(3))
    return small.resize((S, S), Image.BICUBIC)


def note(draw, s):
    """A beamed double note, the family of Apple Music's, but ours: rounder heads, and a beam that
    ripples like a sound wave."""
    import math
    white = (255, 255, 255)
    stem_w = s * 0.055
    left_x, right_x = s * 0.435, s * 0.725          # stems (right edge of each head)
    beam_y0, beam_y1 = s * 0.30, s * 0.245         # top of the beam at each stem
    beam_h = s * 0.085
    # Beam: a thick wave from one stem to the other.
    top, bottom = [], []
    n = 60
    for i in range(n + 1):
        t = i / n
        x = left_x - stem_w + t * (right_x - left_x + stem_w)
        y = beam_y0 + (beam_y1 - beam_y0) * t + math.sin(t * math.pi * 2) * s * 0.018
        top.append((x, y))
        bottom.append((x, y + beam_h))
    draw.polygon(top + bottom[::-1], fill=white)
    # Stems and heads.
    for x, y_top in ((left_x, beam_y0), (right_x, beam_y1)):
        draw.rectangle((x - stem_w, y_top + beam_h * 0.5, x, s * 0.66), fill=white)
        hx, hy, rw, rh = x - stem_w * 0.5 - s * 0.062, s * 0.675, s * 0.098, s * 0.072
        head = Image.new("L", (int(rw * 2.6), int(rw * 2.6)), 0)
        ImageDraw.Draw(head).ellipse((head.width / 2 - rw, head.height / 2 - rh, head.width / 2 + rw, head.height / 2 + rh), fill=255)
        head = head.rotate(22, resample=Image.BICUBIC)
        draw._image.paste(white, (int(hx - head.width / 2), int(hy - head.height / 2)), head)


def main():
    img = gradient()
    # A soft light, top left, like a glossy tile.
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((-S * 0.2, -S * 0.25, S * 0.75, S * 0.6), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.12))
    img = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), img, glow.point(lambda v: v * 0.22))
    # "At home": the note sits on rings, like sound spreading from your own server.
    rings = ImageDraw.Draw(img)
    for k, alpha in ((0.44, 46), (0.36, 34)):
        r = S * k
        layer = Image.new("L", (S, S), 0)
        ImageDraw.Draw(layer).ellipse((S / 2 - r, S / 2 - r, S / 2 + r, S / 2 + r), outline=255, width=int(S * 0.012))
        img = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), img, layer.point(lambda v, a=alpha: v * a / 255))
    note(ImageDraw.Draw(img), S)
    icon = img.resize((1024, 1024), Image.LANCZOS)
    for path in OUT:
        path.parent.mkdir(parents=True, exist_ok=True)
        icon.save(path, optimize=True)
        print("→", path.relative_to(ROOT))


if __name__ == "__main__":
    main()
