# App Store submission pack — Sonalex 1.0

Everything App Store Connect asked you for, ready to copy. Primary language of the
listing: **English (U.S.)**; a French localization is provided too.

| File | What to do with it |
|---|---|
| [`listing-en.txt`](listing-en.txt) | Name, subtitle, promo text, keywords, description, What's New, URLs — paste into the **English (primary)** localization. Char counts verified. |
| [`listing-fr.txt`](listing-fr.txt) | Same fields in French — paste into the **French** localization. |
| [`review-notes.txt`](review-notes.txt) | The **"Notes" / Remarques pour la vérification** field (demo server + login). |
| [`demo-account-setup.md`](demo-account-setup.md) | **Do this first.** Create the `review` demo user so the login actually works. |
| [`assets-and-screenshots.md`](assets-and-screenshots.md) | Exact screenshot/preview sizes for iPhone 6.1"/6.3" and iPad 12.9"/13", and how to make them. |

## The 4 fields you asked for (quick reference)

- **Subtitle (30):** `Music player for Jellyfin` (25)
- **Promotional text (170):** see `listing-en.txt` (153)
- **Keywords (100):** `server,self-hosted,flac,mp3,lyrics,offline,dj,mix,crossfade,playlist,library,audio,album` (88)
- **Description (4000):** see `listing-en.txt`
- **Review notes (4000):** `review-notes.txt`

## Demo login created for Apple

```
Server:   https://my-sonalex.garinio.com
Username: review
Password: Sonalex-Review-IEBc1
```
⚠️ These credentials only work once you create the `review` user on the server —
see `demo-account-setup.md`.

## Submit checklist

- [ ] Apple Developer Program active, `com.alexgarin.sonalex` registered, app created in ASC.
- [ ] `review` demo user created, restricted to a Creative-Commons-only library, `SONALEX_ONLINE` off.
- [ ] `https://my-sonalex.garinio.com` reachable from outside your home, over HTTPS, login tested.
- [ ] EN + FR listings pasted; review notes pasted.
- [ ] Screenshots (real, from the simulator) uploaded: iPhone 1206×2622, iPad 2064×2752.
- [ ] App Privacy = "No data collected"; Age rating answered.
- [ ] Archive in Xcode (Any iOS Device → Product → Archive → Distribute App) and submit.

Full background (age rating, privacy answers, what Apple may object to) is in the parent
[`../README.md`](../README.md).
