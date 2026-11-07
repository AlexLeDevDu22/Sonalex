# Le serveur Sonalex

Ce que l'app ajoute à Jellyfin, servi à l'adresse de Jellyfin sous `/sonalex/` (voir
[`deploy/README.md`](../deploy/README.md) pour l'installation et le relais).

```
backend/
  config.py            réglages (lus dans .env, surchargés par config.ini)
  api/                 le serveur (FastAPI, uvicorn) : python -m uvicorn api.server:app
    server.py          les routes, l'authentification (le jeton Jellyfin de l'app)
    automix.py         Mix : planification et rendu des transitions (ffmpeg)
    mixinfo.py         Mix : analyse des sons (tempo, temps, tonalité, voix)
    connect.py         Connect : appareils, appareil qui joue, commandes
    streamer.py …      modules optionnels : catalogue en ligne (streamer, catalog, saver, radio,
                       daily, credits, library) et synchro Spotify en direct (live_worker)
  full_refreshing.py   synchro Spotify de la nuit (module Spotify)
  sync.py, liked.py, playlists.py, spotify.py, downloading.py …   module Spotify
  utils/               scripts d'entretien ponctuels (à lancer à la main)
```

## Réglages

Tout est dans `backend/.env` (modèle : [`.env.example`](.env.example)) :

| Variable | Rôle |
|---|---|
| `SONALEX_JELLYFIN_URL` | Jellyfin vu depuis cette machine (`http://127.0.0.1:8096`, ou `:8097` derrière le relais Caddy) |
| `JELLYFIN_USER`, `JELLYFIN_PW` | un compte administrateur Jellyfin : le serveur s'en sert pour connaître le chemin des fichiers |
| `JELLYFIN_USER_ID` | facultatif (trouvé à la connexion) |
| `SONALEX_DATA_DIR` | données : `Musics/` (bibliothèque du module Spotify), `logs/`, `temp/`, caches (`mixinfo.json`…) |
| `SONALEX_ONLINE` | `1` = catalogue en ligne |
| `SONALEX_SPOTIFY_SYNC` | `1` = synchro Spotify |
| `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET` | recherche Spotify du catalogue en ligne (tes propres clés, voir plus bas) |
| `LASTFM_API_KEY` | recommandations (lecture automatique, stations), avec le catalogue en ligne |
| `SONALEX_PROXY`, `SONALEX_*_PORT` | lus par `deploy/setup.sh` seulement |

L'app lit `GET /api/health` (`{"features": {"online": …, "spotifySync": …}}`) et n'affiche que ce
que le serveur propose. Les routes d'un module désactivé répondent 404.

## Toujours actif

### Mix : transitions de DJ

L'app joue, sans aucun blanc, des *morceaux* que le serveur prépare : chaque son, avec la
transition depuis le précédent à son début (`automix.py`). Pour chaque enchaînement A → B :

1. **Analyse** (`mixinfo.py`, ~3 s par son, mise en cache) : tempo, grille des temps et des
   mesures au début et à la fin, tonalité (roue de Camelot), volume, et **où est la voix**.
   La voix vient des **paroles synchronisées** (`.lrc` à côté du fichier) ; sans elles, d'une
   estimation prudente. Astuce : le plugin *LrcLib* de Jellyfin, avec l'enregistrement des paroles
   dans les dossiers de la musique, donne des `.lrc` à presque toute une bibliothèque.
2. **Deux règles**, quel que soit le style : B ne commence jamais avant la fin des paroles de A,
   et A a disparu quand B se met à chanter.
3. **Style** :
   - *glide* (tempos à moins de 8 %, ou moitié / double) : le tempo de A glisse vers celui de B
     (rubberband, hauteur conservée, jamais audible sur une voix), un temps fort de A tombe sur le
     premier temps fort de B, les aigus se croisent, les basses s'échangent sur un temps fort. Le
     serveur vérifie ensuite **sur le son rendu** que les deux rythmes tombent ensemble (et recale
     B si une grille était décalée d'un demi-temps). Tonalités qui jurent : mélange plus court ;
   - *echo* (tempos trop éloignés) : un filtre retire les basses de A une fois sa voix finie, A
     s'arrête sur un temps fort et ses deux derniers temps résonnent en échos pendant que B entre ;
   - *join* (pas de rythme exploitable) : A jusqu'à son dernier son, B juste après, sans les
     silences des fichiers.

`GET /api/mix/segment?key=&prev=&next=&start=&until=` planifie et lance le rendu,
`GET /api/mix/stream/{id}` sert le fichier (Apple Lossless). Un seul rendu à la fois.

### Connect

Chaque app garde un WebSocket (`/api/connect`). Par compte Jellyfin, le serveur sait quels
appareils sont là et lequel joue : l'appareil qui joue diffuse son état aux autres, les autres
lui envoient des commandes, et `transfer` fait passer la lecture d'un appareil à l'autre.

## Modules

### Catalogue en ligne (`SONALEX_ONLINE=1`)

Recherche (Spotify, Deezer), pages d'artistes et d'albums, lecture des sons absents de la
bibliothèque (l'audio est trouvé sur YouTube Music et téléchargé pendant la lecture), ajout à la
bibliothèque (le son est rangé et tagué comme les autres), recommandations (Last.fm, Deezer),
artiste du jour, crédits (Genius). **Vérifie que télécharger depuis YouTube est autorisé là où tu
vis avant de l'activer** : c'est sous ta responsabilité.

**Clés** (aucune n'est fournie, chacun utilise les siennes) :

- **Spotify** (recherche, artistes, albums) : crée une app gratuite sur
  [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) et mets son
  *Client ID* et son *Client secret* dans `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` (accès
  officiel aux données publiques). Spotify limite ce que les nouvelles apps peuvent lire :
  certaines playlists éditoriales peuvent manquer.
- **Last.fm** (recommandations) : une clé gratuite sur [last.fm/api](https://www.last.fm/api/account/create).
- Deezer, YouTube Music et LRCLIB (paroles) n'en demandent pas.

> **Ce que j'utilise de mon côté :** pas de clés développeur Spotify, mais le jeton du compte que
> donne le service [chosic.com](https://www.chosic.com/spotify-playlist-analyzer/) (son
> *Playlist Analyzer*, une fois connecté à Spotify), dans `backend/chosic_data.json` (modèle :
> [`chosic_data.json.example`](chosic_data.json.example)). Le catalogue s'en sert quand les clés
> ci-dessus sont vides. Ce n'est pas une API officielle : ça peut s'arrêter du jour au lendemain,
> et c'est à toi de voir si tu veux l'utiliser.

### Synchro Spotify (`SONALEX_SPOTIFY_SYNC=1`) — expérimental

Jellyfin est maître : favoris et playlists modifiés dans Jellyfin (ou l'app) sont poussés vers
Spotify en direct ; chaque nuit, `full_refreshing.py` fait l'inverse (nouveaux likes et
playlists Spotify téléchargés), plus l'entretien (fichiers manquants, doublons, paroles). Il lui
faut un jeton **de ton compte** Spotify (lire tes likes, modifier tes playlists : des clés
développeur seules ne suffisent pas) : celui de chosic.com, comme décrit plus haut, dans
`backend/chosic_data.json` avec `SPOTIFY_USER_ID` (ton identifiant Spotify). Avec
`ONLY_LIKED = True` (`config.ini`), les sons qui ne sont plus likés ni dans une playlist suivie
**sont supprimés** la nuit suivante.

```bash
cd backend && .venv/bin/python spotify_refreshing.py --dry-run   # premier rattrapage, à blanc
```

## Développer

```bash
cd backend && .venv/bin/python -m uvicorn api.server:app --port 18098 --reload
```

Les journaux de l'app (événements du lecteur) arrivent dans `<données>/logs/player-debug.log`.
