# Sonalex on the App Store

Everything App Store Connect asks for, ready to copy. Primary language: **English (U.S.)** (the
app is in English); a French listing is provided too, for the *French* localization.

## Before submitting

- [ ] An **Apple Developer Program** membership ($99/year): a free Apple ID can't publish.
- [ ] The `com.alexgarin.sonalex` identifier registered (*Certificates, IDs & Profiles*), and the
      app created in App Store Connect with that same identifier (iPhone, iPad, and Mac if you
      publish the Mac version).
- [ ] **A demo server for Apple** (see *Notes for review*): without it, the app is rejected.
- [ ] The links work: **public** GitHub repository (`AppInfo.repository` in
      `ios/Sonalex/App/AppInfo.swift`) and `PRIVACY.md` (privacy policy URL).
- [ ] Screenshots taken on the demo library (see below).
- [ ] Archive: Xcode → destination *Any iOS Device* → **Product → Archive** → *Distribute App*.
      For the Mac: destination *Any Mac (Mac Catalyst)*, same thing.

## Listing (English, primary)

| Field | Content |
|---|---|
| Name (30) | `Sonalex` |
| Subtitle (30) | `Music player for Jellyfin` |
| Category | Music (secondary: Entertainment) |
| Price | Free |
| Keywords (100) | `server,self-hosted,flac,mp3,lyrics,offline,dj,mix,crossfade,playlist,library,audio,album` |
| Support URL | `https://github.com/AlexLeDevDu22/sonalex/issues` |
| Marketing URL | `https://github.com/AlexLeDevDu22/sonalex` |
| Privacy Policy URL | `https://github.com/AlexLeDevDu22/sonalex/blob/main/PRIVACY.md` |
| Copyright | `2026 <your name or handle>` |

**Promotional text (170)**

> Your albums, playlists and lyrics, from your own Jellyfin server. DJ-style transitions between songs with the free, open-source Sonalex server.

**Description**

> Sonalex is a music player for your own Jellyfin server. Sign in with your usual Jellyfin account and get your whole library in a fast, beautiful app made for music.
>
> YOUR LIBRARY
> • Home with what you played lately, your most played songs and some to rediscover
> • Artists, albums, songs, genres, playlists and favorites
> • Instant search across your whole library
> • Create and edit playlists, favorite a song in one tap
>
> A REAL PLAYER
> • Full-screen player in the colors of the artwork
> • Synced lyrics that follow the music
> • Editable queue, smart shuffle that spreads artists out
> • Gapless playback
> • AirPlay, lock screen, Dynamic Island
>
> OFFLINE TOO
> • Download a song, an album or a playlist to your device
> • Your most played favorites download themselves
>
> ON ALL YOUR DEVICES
> • iPhone, iPad and a real Mac app: sidebar, keyboard shortcuts, menu bar controls
>
> WITH THE SONALEX SERVER (OPTIONAL)
> Install the free, open-source Sonalex server next to your Jellyfin to go further:
> • Mix: DJ-style transitions between your songs, beat-matched, that wait for the lyrics to end
> • Connect: start the music on your Mac, carry on on your iPhone, control one device from another
>
> YOUR MUSIC STAYS HOME
> Sonalex has no account, no ads and collects no data: the app only talks to your server.
>
> Sonalex requires a Jellyfin server (free, https://jellyfin.org): yours, or one someone made you an account on. Sonalex is not affiliated with the Jellyfin project.

**What's New (version 1.0)**

> First release of Sonalex.

## Listing (French)

| Champ | Contenu |
|---|---|
| Sous-titre | `Lecteur de musique Jellyfin` |
| Mots-clés | `serveur,auto-hébergé,flac,mp3,paroles,hors ligne,dj,mix,transitions,playlist,bibliothèque,album` |

**Texte promotionnel**

> Tes albums, tes playlists et tes paroles, sur ton serveur Jellyfin. Des transitions de DJ entre tes sons avec le serveur Sonalex, gratuit et open source.

**Description**

> Sonalex est un lecteur de musique pour ton propre serveur Jellyfin. Connecte-toi avec ton compte Jellyfin habituel et retrouve toute ta bibliothèque dans une app rapide, belle et pensée pour la musique.
>
> TA BIBLIOTHÈQUE
> • Accueil avec tes écoutes récentes, tes sons les plus joués et ceux à redécouvrir
> • Artistes, albums, morceaux, genres, playlists et favoris
> • Recherche instantanée dans toute ta bibliothèque
> • Crée et modifie tes playlists, ajoute tes favoris d'un geste
>
> UN VRAI LECTEUR
> • Lecteur plein écran aux couleurs de la pochette
> • Paroles synchronisées qui défilent avec la musique
> • File d'attente modifiable, aléatoire intelligent qui varie les artistes
> • Enchaînement sans blanc entre les morceaux
> • AirPlay, écran verrouillé, Dynamic Island
>
> MÊME SANS RÉSEAU
> • Télécharge un son, un album ou une playlist sur ton appareil
> • Tes favoris les plus écoutés se téléchargent tout seuls
>
> SUR TOUS TES APPAREILS
> • iPhone, iPad et une vraie app Mac : barre latérale, raccourcis clavier, contrôles dans la barre des menus
>
> AVEC LE SERVEUR SONALEX (OPTIONNEL)
> Installe le serveur Sonalex, gratuit et open source, à côté de ton Jellyfin pour aller plus loin :
> • Mix : des transitions de DJ entre tes sons, calées sur le tempo, qui attendent la fin des paroles
> • Connect : lance la musique sur le Mac, continue-la sur l'iPhone, pilote un appareil depuis un autre
>
> TA MUSIQUE RESTE CHEZ TOI
> Sonalex n'a pas de compte, pas de publicité et ne collecte aucune donnée : l'app ne parle qu'à ton serveur.
>
> Sonalex nécessite un serveur Jellyfin (gratuit, https://jellyfin.org), le tien ou celui de quelqu'un qui t'a créé un compte. L'app est en anglais. Sonalex n'est pas affilié au projet Jellyfin.

## Notes for review (App Review Information)

Apple must be able to sign in and play something. Set up on your Jellyfin:

1. a **demo** library with only royalty-free music (e.g. Creative Commons albums from
   [Free Music Archive](https://freemusicarchive.org) or [Jamendo](https://www.jamendo.com));
2. a `review` user (strong password) that sees **only** that library;
3. your server reachable from the Internet, preferably over **https**.

*Sign-in required*: check it, and give the server address in the notes (there's no "server" field):

> Sonalex is a client for Jellyfin, a free self-hosted media server: users sign in to their own server. To review it, use our demo server:
>
> Server: https://<your-domain>
> Username: review
> Password: <password>
>
> 1. Type the server address, username and password, then tap "Sign In".
> 2. Open "Library" or "Home" and play any song. The demo library contains only Creative Commons music.
> 3. (Keep this line only if the Sonalex server runs on the demo server.) The demo server also runs the optional Sonalex companion server (open source: https://github.com/AlexLeDevDu22/sonalex). In the player, open the queue (list icon) and tap the wand to turn on "Mix" (DJ transitions between songs), then skip near the end of a song to hear one.
>
> NSAllowsArbitraryLoads: users connect to their own media server, at an address they type; many home servers only offer plain http on the local network, so the app can't require https.

## App Privacy

- *Do you or your third-party partners collect data from this app?* → **No, we do not collect data from this app.**
  The app sends nothing to the developer; it only talks to the servers the user chooses
  (`PRIVACY.md`). The `ios/Sonalex/Resources/PrivacyInfo.xcprivacy` manifest says the same.
- *Export compliance*: already answered in the app (`ITSAppUsesNonExemptEncryption = NO`: only
  Apple's HTTPS).

## Age rating

The questions are about the **app's** content: it provides none, it plays the user's server's.
Answer *No / None* everywhere, except:
- *User-generated content / unrestricted web access*: **No** (the app doesn't open web pages);
- if you'd rather be careful about the lyrics shown (those of the user's songs), check
  *infrequent profanity*: the rating goes up one step.

## Images

| What | Size | File |
|---|---|---|
| Icon | 1024 × 1024, no transparency | in the app (`AppIcon`): App Store Connect takes it from the build. Copy: `icon-1024.png` |
| iPhone 6.9" screenshots | 1320 × 2868 (portrait) | `screenshots/iphone/` |
| iPad 13" screenshots | 2064 × 2752 (portrait) | `screenshots/ipad/` — required: the app runs on iPad |
| Mac screenshots | 2880 × 1800 | `screenshots/mac/` — if you publish the Mac version |
| App previews (optional) | 886 × 1920, 15 to 30 s | simulator recording |
| 16:9 / 9:16 banners | 1920 × 1080, 1080 × 1920 | `banners/` |

App Store Connect asks for **1 to 10 screenshots** per size; smaller devices are derived from the
largest. There's no "header image" on a standard app page: 16:9 and 9:16 images are for **in-app
events** (the card shown in search results, and the event page), which is what the banners are for.

### Taking the screenshots

Apple rejects screenshots that don't show the real app: take them in the app, on the demo library
(no commercial album artwork: copyright).

1. Xcode → **iPhone 17 Pro Max** simulator (6.9") → ▶, sign in to the demo server.
2. Put the app in the state you want, **⌘S** in the simulator (full-resolution screenshot).
3. Put them in `docs/app-store/raw/iphone/` (`01-home.png`, `02-mix.png`…, in order), same with
   the **iPad Pro 13"** simulator (`raw/ipad/`) and a Mac window (`raw/mac/`).
4. `backend/.venv/bin/python docs/app-store/tools/make_store_images.py screenshots`
   → `screenshots/<device>/`, with the captions of `captions.json` (one per screenshot, in order).

Suggested iPhone order (the first 3 matter most, they show in search results): home · player
during a Mix · lyrics · library · downloads · Connect.

The icon and banners are made again with `tools/make_icon.py` and
`tools/make_store_images.py banners`.

## What Apple may object to

- **The look**: SwiftUI, SF Symbols and Apple's components are normal and encouraged. The icon is
  in the family of music app icons (white note on a colored tile) but has its own shape and colors
  (a rippling beam, violet, rings): don't make it closer to Apple Music's, and never use Apple
  Music's name or logo in the app or the screenshots.
- **The online catalog** (`SONALEX_ONLINE` server module): downloading from YouTube and using the
  Spotify catalog without permission breaks guidelines 5.2.2 and 5.2.3. It's off by default and
  must be off on the demo server.
- **The demo server** not answering during review: rejection as "app not functional".
