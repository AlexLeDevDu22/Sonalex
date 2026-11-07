"""Store images of Sonalex, at the sizes App Store Connect asks for.

    backend/.venv/bin/python docs/app-store/tools/make_store_images.py screenshots
        docs/app-store/raw/<device>/*.png  →  docs/app-store/screenshots/<device>/*.png
        Real screenshots of the app (simulator: ⌘S), framed on the Sonalex background with the
        caption of docs/app-store/captions.json. <device>: iphone, ipad, mac.
    backend/.venv/bin/python docs/app-store/tools/make_store_images.py banners
        docs/app-store/banners/: 16:9 and 9:16 artwork (in-app event card / details page, socials).

Apple's rules: a screenshot must show the app in use; text around it is fine. No other brand's
logos, and no artwork / music the app's owner hasn't the rights to (use free-licensed music).
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
STORE = HERE.parent
ICON = STORE / "icon-1024.png"
FONT_DIRS = [Path("/usr/share/fonts/truetype/nunito-sans"), Path("/usr/share/fonts/truetype/lato"),
             Path("/System/Library/Fonts"), Path("/Library/Fonts")]

# Sizes accepted by App Store Connect: the largest of each family, smaller devices are derived.
SIZES = {
    "iphone": (1320, 2868),  # 6.9" (iPhone 16/17 Pro Max)
    "ipad": (2064, 2752),    # 13" (iPad Pro M4)
    "mac": (2880, 1800),     # 16:10
}
TOP, MIDDLE, BOTTOM = (38, 20, 104), (124, 92, 255), (255, 84, 150)


def font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    names = (["NunitoSans-ExtraBold.ttf", "NunitoSans-Bold.ttf", "Lato-Black.ttf", "Lato-Bold.ttf", "SFNS.ttf"]
             if bold else ["NunitoSans-Regular.ttf", "Lato-Regular.ttf", "SFNS.ttf"])
    for d in FONT_DIRS:
        for n in names:
            for f in d.rglob(n) if d.exists() else []:
                return ImageFont.truetype(str(f), size)
    return ImageFont.load_default(size)


def background(w: int, h: int) -> Image.Image:
    small = Image.new("RGB", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x * 0.35 + y) / (63 * 1.35)
            a, b, u = (TOP, MIDDLE, t / 0.6) if t < 0.6 else (MIDDLE, BOTTOM, (t - 0.6) / 0.4)
            px[x, y] = tuple(round(a[i] + (b[i] - a[i]) * u) for i in range(3))
    return small.resize((w, h), Image.BICUBIC)


def rounded(img: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *img.size), radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def text_block(draw, lines, box_w, y, sizes, fill=(255, 255, 255)):
    for text, size, bold in zip(lines, sizes, (True, False)):
        if not text:
            continue
        f = font(size, bold)
        # Wrap to the width.
        words, rows, row = text.split(), [], ""
        for word in words:
            test = f"{row} {word}".strip()
            if draw.textlength(test, font=f) > box_w and row:
                rows.append(row)
                row = word
            else:
                row = test
        rows.append(row)
        for r in rows:
            draw.text((draw.im.size[0] / 2, y), r, font=f, fill=fill, anchor="mt")
            y += int(size * 1.18)
        y += int(size * 0.35)
    return y


def frame(raw: Path, device: str, caption: list[str], out: Path):
    w, h = SIZES[device]
    canvas = background(w, h)
    draw = ImageDraw.Draw(canvas)
    landscape = w > h
    title, subtitle = (caption + ["", ""])[:2]
    y = text_block(draw, [title, subtitle], w * 0.84, int(h * (0.06 if not landscape else 0.07)),
                   [int(w * (0.075 if not landscape else 0.04)), int(w * (0.04 if not landscape else 0.022))])
    shot = Image.open(raw).convert("RGB")
    top = y + int(h * 0.02)
    room_w, room_h = w * (0.84 if not landscape else 0.8), h - top - h * 0.04
    scale = min(room_w / shot.width, room_h / shot.height)
    shot = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
    radius = int(shot.width * (0.075 if device == "iphone" else 0.03))
    shot = rounded(shot, radius)
    x = (w - shot.width) // 2
    shadow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x, top + 18, x + shot.width, top + 18 + shot.height), radius=radius, fill=140)
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    canvas.paste((10, 4, 30), (0, 0), shadow)
    canvas.paste(shot, (x, top), shot)
    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out, optimize=True)
    print(f"→ {out.relative_to(STORE)} ({w}×{h})")


def screenshots():
    captions = json.loads((STORE / "captions.json").read_text(encoding="utf8"))
    found = False
    for device in SIZES:
        raws = sorted((STORE / "raw" / device).glob("*.png"))
        for i, raw in enumerate(raws):
            found = True
            caption = captions.get(device, captions.get("iphone", []))
            frame(raw, device, caption[i] if i < len(caption) else [], STORE / "screenshots" / device / raw.name)
    if not found:
        print("Aucune capture dans docs/app-store/raw/{iphone,ipad,mac}/ : voir docs/app-store/README.md")


def banners():
    icon = Image.open(ICON).convert("RGB")
    for name, (w, h) in {"banner-16x9.png": (1920, 1080), "banner-9x16.png": (1080, 1920)}.items():
        canvas = background(w, h)
        draw = ImageDraw.Draw(canvas)
        side = int(min(w, h) * 0.34)
        logo = rounded(icon.resize((side, side), Image.LANCZOS), int(side * 0.225))
        if w > h:
            x, y = int(w * 0.12), (h - side) // 2
            canvas.paste(logo, (x, y), logo)
            tx = x + side + int(w * 0.05)
            draw.text((tx, h * 0.40), "Sonalex", font=font(int(h * 0.14)), fill="white", anchor="lm")
            draw.text((tx, h * 0.56), "Ta musique Jellyfin, enfin belle.", font=font(int(h * 0.055), False),
                      fill="white", anchor="lm")
        else:
            x, y = (w - side) // 2, int(h * 0.26)
            canvas.paste(logo, (x, y), logo)
            draw.text((w / 2, y + side + h * 0.07), "Sonalex", font=font(int(w * 0.16)), fill="white", anchor="mt")
            text_block(draw, ["", "Ta musique Jellyfin, enfin belle."], w * 0.8, y + side + int(h * 0.17),
                       [0, int(w * 0.06)])
        out = STORE / "banners" / name
        out.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(out, optimize=True)
        print(f"→ {out.relative_to(STORE)} ({w}×{h})")


if __name__ == "__main__":
    {"screenshots": screenshots, "banners": banners}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: print(__doc__))()
