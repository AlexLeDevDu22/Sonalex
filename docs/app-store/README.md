# Sonalex sur l'App Store

Tout ce qu'App Store Connect demande, prêt à copier. Langue principale : **français**
(l'app est en français) ; une version anglaise est fournie pour la fiche *English (U.S.)*.

## Avant de soumettre

- [ ] Compte **Apple Developer Program** (99 €/an) : l'Apple ID gratuit ne peut pas publier.
- [ ] Identifiant `com.alexgarin.sonalex` enregistré (*Certificates, IDs & Profiles*), l'app créée
      dans App Store Connect avec ce même identifiant (iPhone, iPad, et Mac si tu publies la
      version Mac).
- [ ] **Un serveur de démo pour Apple** (voir *Notes pour la review*) : sans lui, l'app est refusée.
- [ ] Les liens marchent : dépôt GitHub **public** (`AppInfo.repository` dans
      `ios/Sonalex/App/AppInfo.swift`) et `PRIVACY.md` (URL de confidentialité).
- [ ] Captures d'écran prises sur la bibliothèque de démo (voir plus bas).
- [ ] Archive : Xcode → destination *Any iOS Device* → **Product → Archive** → *Distribute App*.
      Pour le Mac : destination *Any Mac (Mac Catalyst)*, même chose.

## Fiche (français)

| Champ | Contenu |
|---|---|
| Nom (30) | `Sonalex` |
| Sous-titre (30) | `Lecteur de musique Jellyfin` |
| Catégorie | Musique (secondaire : Divertissement) |
| Prix | Gratuit |
| Mots-clés (100) | `serveur,auto-hébergé,flac,mp3,paroles,hors ligne,dj,mix,transitions,playlist,bibliothèque,album` |
| URL d'assistance | `https://github.com/AlexLeDevDu22/sonalex/issues` |
| URL marketing | `https://github.com/AlexLeDevDu22/sonalex` |
| URL de confidentialité | `https://github.com/AlexLeDevDu22/sonalex/blob/main/PRIVACY.md` |
| Copyright | `2026 <ton nom ou pseudo>` |

**Texte promotionnel (170)**

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
> Sonalex nécessite un serveur Jellyfin (gratuit, https://jellyfin.org), le tien ou celui de quelqu'un qui t'a créé un compte. Sonalex n'est pas affilié au projet Jellyfin.

**Nouveautés (version 1.0)**

> Première version de Sonalex.

## Fiche (English)

| Field | Content |
|---|---|
| Name | `Sonalex` |
| Subtitle | `Music player for Jellyfin` |
| Keywords | `server,self-hosted,flac,mp3,lyrics,offline,dj,mix,crossfade,playlist,library,audio,album` |

**Promotional text**

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
> Sonalex requires a Jellyfin server (free, https://jellyfin.org): yours, or one someone made you an account on. The app is in French for now. Sonalex is not affiliated with the Jellyfin project.

## Notes pour la review (App Review Information)

Apple doit pouvoir se connecter et écouter quelque chose. Prépare sur ton Jellyfin :

1. une bibliothèque **de démo** avec uniquement de la musique libre de droits (par ex. des albums
   sous licence Creative Commons de [Free Music Archive](https://freemusicarchive.org) ou
   [Jamendo](https://www.jamendo.com)) ;
2. un utilisateur `review` (mot de passe fort) qui ne voit **que** cette bibliothèque ;
3. ton serveur joignable depuis Internet, de préférence en **https**.

*Sign-in required* : coche, et donne l'adresse du serveur dans les notes (il n'y a pas de champ
« serveur ») :

> Sonalex is a client for Jellyfin, a free self-hosted media server: users sign in to their own server. To review it, use our demo server:
>
> Server: https://<ton-domaine>
> Username: review
> Password: <mot de passe>
>
> 1. Type the server address, username and password, then tap "Se connecter" (the app is in French).
> 2. Open "Bibliothèque" or "Accueil" and play any song. The demo library contains only Creative Commons music.
> 3. (Garde cette ligne seulement si le serveur Sonalex tourne sur le serveur de démo.) The demo server also runs the optional Sonalex companion server (open source: https://github.com/AlexLeDevDu22/sonalex). In the player, open the queue (list icon) and tap the wand to turn on "Mix" (DJ transitions between songs), and skip near the end of a song to hear one.
>
> NSAllowsArbitraryLoads: users connect to their own media server, at an address they type; many home servers only offer plain http on the local network, so the app can't require https.

## Confidentialité de l'app (App Privacy)

- *Do you or your third-party partners collect data from this app?* → **No, we do not collect data from this app.**
  L'app n'envoie rien au développeur ; elle ne parle qu'aux serveurs que l'utilisateur choisit
  (`PRIVACY.md`). Le manifeste `ios/Sonalex/Resources/PrivacyInfo.xcprivacy` dit la même chose.
- *Export compliance* : déjà répondu dans l'app (`ITSAppUsesNonExemptEncryption = NO` : uniquement
  le HTTPS d'Apple).

## Classement par âge

Les questions portent sur le contenu **de l'app** : elle n'en fournit aucun, elle lit celui du
serveur de l'utilisateur. Réponds *Non / Aucun* partout, sauf :
- *Contenu généré par les utilisateurs / accès web illimité* : **Non** (l'app n'ouvre pas de pages web) ;
- si tu préfères être prudent à cause des paroles affichées (celles des sons de l'utilisateur),
  coche *grossièretés peu fréquentes* : le classement monte d'un cran.

## Images

| Quoi | Taille | Fichier |
|---|---|---|
| Icône | 1024 × 1024, sans transparence | dans l'app (`AppIcon`) : App Store Connect la prend dans la build. Copie : `icon-1024.png` |
| Captures iPhone 6,9" | 1320 × 2868 (portrait) | `screenshots/iphone/` |
| Captures iPad 13" | 2064 × 2752 (portrait) | `screenshots/ipad/` — obligatoires : l'app tourne sur iPad |
| Captures Mac | 2880 × 1800 | `screenshots/mac/` — si tu publies la version Mac |
| Aperçus vidéo (facultatif) | 886 × 1920, 15 à 30 s | enregistrement du simulateur |
| Bannières 16:9 / 9:16 | 1920 × 1080, 1080 × 1920 | `banners/` |

App Store Connect demande **de 1 à 10 captures** par taille ; les plus petits appareils sont
déduits des plus grands. Il n'y a pas d'« image d'en-tête » sur une fiche d'app standard : les
images en 16:9 et 9:16 servent aux **événements in-app** (carte affichée dans les résultats de
recherche, page de l'événement), c'est à ça que correspondent les bannières.

### Prendre les captures

Apple refuse les captures qui ne montrent pas l'app en vrai : prends-les dans l'app, sur la
bibliothèque de démo (pas de pochettes d'albums du commerce : droits d'auteur).

1. Xcode → simulateur **iPhone 17 Pro Max** (6,9") → ▶, connecte-toi au serveur de démo.
2. Mets l'app dans l'état voulu, **⌘S** dans le simulateur (capture en pleine résolution).
3. Range-les dans `docs/app-store/raw/iphone/` (`01-accueil.png`, `02-mix.png`…, dans l'ordre),
   pareil avec le simulateur **iPad Pro 13"** (`raw/ipad/`) et une fenêtre Mac (`raw/mac/`).
4. `backend/.venv/bin/python docs/app-store/tools/make_store_images.py screenshots`
   → `screenshots/<appareil>/`, avec les légendes de `captions.json` (une par capture, dans l'ordre).

Ordre conseillé pour l'iPhone (les 3 premières comptent le plus, elles s'affichent dans la
recherche) : accueil · lecteur pendant un Mix · paroles · bibliothèque · téléchargements · Connect.

L'icône et les bannières se refont avec `tools/make_icon.py` et `tools/make_store_images.py banners`.

## Ce qu'Apple risque de reprocher

- **Le design « à la Apple Music »** : utiliser SwiftUI, les SF Symbols et les composants d'Apple
  est normal et encouragé. Ce qui était risqué, c'était **l'ancienne icône** (note blanche sur
  rouge, comme Apple Music) et le rouge exact d'Apple Music : remplacés par l'icône Sonalex et un
  violet à nous. Ne mets aucun logo ni nom d'Apple Music dans l'app ni sur les captures.
- **Le catalogue en ligne** (module `SONALEX_ONLINE` du serveur) : télécharger depuis YouTube et
  utiliser le catalogue Spotify sans autorisation enfreint les règles 5.2.2 et 5.2.3. Il est
  désactivé par défaut, et il doit l'être sur le serveur de démo. Voir les risques dans la réponse
  qui accompagne ces fichiers avant de le laisser dans le projet public.
- **Le serveur de démo** qui ne répond pas pendant la review : refus « app non fonctionnelle ».
