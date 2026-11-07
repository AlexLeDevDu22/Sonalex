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

TOP_LEFT, BOTTOM_RIGHT = (38, 20, 104), (255, 84, 150)  # deep indigo → pink
MIDDLE = (124, 92, 255)  # the app's accent


def gradient() -> Image.Image:
    img = Image.new("RGB", (S, S))
    px = img.load()
    small = Image.new("RGB", (256, 256))
    sp = small.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            a, b, u = (TOP_LEFT, MIDDLE, t / 0.55) if t < 0.55 else (MIDDLE, BOTTOM_RIGHT, (t - 0.55) / 0.45)
            sp[x, y] = tuple(round(a[i] + (b[i] - a[i]) * u) for i in range(3))
    return small.resize((S, S), Image.BICUBIC)


def main():
    img = gradient()
    # A soft light behind the waveform.
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((S * 0.18, S * 0.18, S * 0.82, S * 0.82), fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.09))
    img = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), img, glow.point(lambda v: v * 0.35))
    # The waveform: seven rounded bars, the shape of a sound swelling and fading.
    draw = ImageDraw.Draw(img)
    heights = [0.20, 0.38, 0.62, 0.82, 0.62, 0.38, 0.20]
    bar, gap = S * 0.068, S * 0.042
    total = len(heights) * bar + (len(heights) - 1) * gap
    x = (S - total) / 2
    for h in heights:
        half = S * 0.5 * h / 2 + bar / 2
        draw.rounded_rectangle((x, S / 2 - half, x + bar, S / 2 + half), radius=bar / 2, fill=(255, 255, 255))
        x += bar + gap
    icon = img.resize((1024, 1024), Image.LANCZOS)
    for path in OUT:
        path.parent.mkdir(parents=True, exist_ok=True)
        icon.save(path, optimize=True)
        print("→", path.relative_to(ROOT))


if __name__ == "__main__":
    main()
