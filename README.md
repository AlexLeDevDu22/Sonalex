<p align="center"><img src="docs/app-store/icon-1024.png" width="128" alt=""></p>

# Sonalex

**Le lecteur de musique pour ton serveur [Jellyfin](https://jellyfin.org)**, sur iPhone, iPad et Mac.

> *English: Sonalex is a native music player for any Jellyfin server (iOS, iPadOS, macOS). An
> optional self-hosted companion server adds DJ-style transitions and multi-device playback. The
> app is in French for now.*

Sonalex se connecte à **n'importe quel serveur Jellyfin** avec ton compte habituel : il n'y a
pas de compte Sonalex, et rien n'est envoyé ailleurs que sur ton serveur.

| Avec Jellyfin seul | Avec le serveur Sonalex en plus (optionnel) |
|---|---|
| Accueil, nouveautés, bibliothèque (artistes, albums, morceaux, favoris, genres, playlists) | **Mix** : transitions de DJ entre les sons (calées sur le tempo, jamais par-dessus une voix) |
| Lecteur plein écran, paroles synchronisées, file d'attente, aléatoire intelligent | **Connect** : un appareil joue, les autres le pilotent ; passer la lecture de l'iPhone au Mac |
| Téléchargements pour écouter hors connexion | Modules activables par le propriétaire du serveur (voir plus bas) |
| AirPlay, écran verrouillé, Dynamic Island, Mac avec barre des menus | |

## L'app

- **App Store** : bientôt.
- **Compiler soi-même** : [`ios/README.md`](ios/README.md) (Xcode 26, XcodeGen).

À la connexion, tape l'adresse de ton Jellyfin (par ex. `https://jellyfin.exemple.fr` ou
`http://192.168.1.10:8096`). Si un serveur Sonalex répond à la même adresse sous `/sonalex`, l'app
l'utilise toute seule. Sinon, elle fonctionne comme un client Jellyfin classique.

## Le serveur Sonalex (optionnel)

Un petit serveur Python (FastAPI) qui tourne **sur la même machine que Jellyfin** : il lit les
fichiers de ta bibliothèque pour préparer les transitions du Mix.

### Installation (Debian, Ubuntu, Raspberry Pi OS)

```bash
git clone https://github.com/AlexLeDevDu22/sonalex.git
cd sonalex
bash deploy/setup.sh          # crée backend/.env et s'arrête : remplis-le
nano backend/.env             # adresse de Jellyfin + un compte administrateur
bash deploy/setup.sh          # installe tout, démarre les services, vérifie
```

Le script est idempotent : il ne refait que ce qui manque. Il peut aussi faire une seule étape
(`packages`, `data`, `python`, `proxy`, `services`, `check`). Détails, ports et configuration avec
ton propre reverse proxy (nginx, Caddy, Traefik) : [`deploy/README.md`](deploy/README.md).

Fonctionnement du serveur (Mix, Connect, modules, API) : [`backend/README.md`](backend/README.md).

### Modules

Dans `backend/.env`. Tous désactivés par défaut :

| Réglage | Ce que ça ajoute |
|---|---|
| `SONALEX_ONLINE=1` | **Catalogue en ligne** : chercher, écouter et ajouter à la bibliothèque des sons qu'elle n'a pas. L'audio vient de YouTube : vérifie que c'est autorisé chez toi avant de l'activer. |
| `SONALEX_SPOTIFY_SYNC=1` | **Synchro Spotify** : likes et playlists suivent un compte Spotify, la nuit et en direct. Expérimental. |

**Aucune clé n'est fournie avec le projet** : chacun met les siennes dans `backend/.env`
(Spotify, Last.fm). Comment les obtenir, et ce que j'utilise de mon côté :
[`backend/README.md`](backend/README.md#modules).

## Structure

| Dossier | Contenu |
|---|---|
| `ios/` | L'app (SwiftUI, iOS 18+, Mac Catalyst) |
| `backend/` | Le serveur Sonalex et la synchro Spotify |
| `deploy/` | Installation : `setup.sh`, modèles des services systemd et du relais Caddy |
| `docs/` | Intégrations Mac (`now-playing-mac.md`), fiche App Store (`app-store/`) |

## Confidentialité

L'app ne collecte rien : voir [`PRIVACY.md`](PRIVACY.md).

## Contribuer

Les issues et pull requests sont bienvenues. Sonalex n'est pas affilié au projet Jellyfin, ni à
Spotify, YouTube ou Apple.

## Licence

[MIT](LICENSE) : tu peux utiliser, modifier et redistribuer le code, y compris dans une app
publiée, en gardant la mention de copyright.
