# Assets — exact sizes for the slots App Store Connect is showing you

App Store Connect now asks for **iPhone 6.1"/6.3"** and **iPad 12.9"/13"** (newer than the
6.9"/13" the old README mentioned). Below are the exact sizes it accepts, reformatted.

Rule that overrides everything: **a screenshot must show the real app.** Apple rejects
mockups / fake UI. I can't capture your native iOS app from here (no Mac/simulator on the
Pi), so these are the specs + the recipe — the actual PNGs come from the simulator.

Per slot you may upload: **up to 3 app previews** (video) and **up to 10 screenshots**.
You only need to fill the **largest** size of each family — Apple derives the smaller one.

---

## iPhone — "6.1" or 6.3" displays"

| Asset | Orientation | Accepted sizes (px) | Recommended |
|---|---|---|---|
| **App previews** (video, .mov/.mp4, 15–30 s, up to 3) | landscape / portrait | 1920 × 886 · 886 × 1920 | 886 × 1920 (portrait) |
| **Screenshots** (up to 10) | 6.1" | 2556 × 1179 · **1179 × 2556** | portrait |
| **Screenshots** (up to 10) | 6.3" | 2622 × 1206 · **1206 × 2622** | **1206 × 2622 (portrait)** |

→ Upload the **6.3" portrait (1206 × 2622)** set; Apple fills 6.1" (1179 × 2556) from it.

## iPad — "12.9" or 13" displays"

| Asset | Orientation | Accepted sizes (px) | Recommended |
|---|---|---|---|
| **App previews** (video, up to 3) | landscape / portrait | 1600 × 1200 · 1200 × 1600 | 1200 × 1600 (portrait) |
| **Screenshots** (up to 10) | 12.9" | 2732 × 2048 · **2048 × 2732** | portrait |
| **Screenshots** (up to 10) | 13" | 2752 × 2064 · **2064 × 2752** | **2064 × 2752 (portrait)** |

→ Upload the **13" portrait (2064 × 2752)** set; Apple fills 12.9" (2048 × 2732) from it.

> There is **no "header image"** on a normal App Store product page. The 16:9 / 9:16
> images in `../banners/` are only for **in-app events** (the card shown in search
> results). Ignore them for a standard submission.

---

## The icon

1024 × 1024, no transparency. App Store Connect takes it from the build (`AppIcon`).
A copy is at `../icon-1024.png` if you need to upload it manually.

---

## How to actually make the screenshots (the only valid way)

1. Xcode → run on the **iPhone 16 Pro** simulator (6.3", gives 1206 × 2622) and the
   **iPad Pro 13"** simulator (gives 2064 × 2752). Sign in to the demo server.
2. Put the app in the state you want → **⌘S** in the simulator = a full-resolution PNG
   on the Desktop.
3. Drop them in order into:
   - `docs/app-store/raw/iphone/` → `01-home.png`, `02-mix.png`, `03-lyrics.png`, …
   - `docs/app-store/raw/ipad/`   → same idea
4. Frame them with captions (sizes already set to 1206 × 2622 / 2064 × 2752):
   ```bash
   backend/.venv/bin/python docs/app-store/tools/make_store_images.py screenshots
   ```
   Output → `docs/app-store/screenshots/iphone/` and `.../ipad/`, ready to upload.

**First 3 screenshots matter most** (they show in search results). Suggested order:
home · player during a Mix · live lyrics · library · downloads · Connect.
Captions live in `../captions.json` (one per screenshot, in order) — edit freely.

### App previews (optional)
Record the simulator (File → Record Screen, or `xcrun simctl io booted recordVideo`),
15–30 s, trim to the sizes above. Optional — skip for a first release if you're short
on time; screenshots alone are enough to submit.
