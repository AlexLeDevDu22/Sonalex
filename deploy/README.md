# Installer le serveur Sonalex

Le serveur Sonalex s'installe **sur la machine où tourne Jellyfin** (il lit les fichiers de la
bibliothèque pour préparer le Mix). Testé sur Raspberry Pi OS (Debian 13) avec Jellyfin 12 ;
n'importe quel Debian / Ubuntu récent convient.

## Installation

```bash
git clone https://github.com/AlexLeDevDu22/sonalex.git && cd sonalex
bash deploy/setup.sh
```

Le premier lancement crée `backend/.env` à partir de `backend/.env.example` et s'arrête :
remplis au moins l'adresse de Jellyfin et un compte **administrateur** (le serveur en a besoin
pour connaître le chemin des fichiers), puis relance `bash deploy/setup.sh`.

Le script est idempotent (on peut le relancer autant qu'on veut) et découpé en étapes :

| Étape | Ce qu'elle fait | sudo |
|---|---|---|
| `packages` | ffmpeg, python3-venv, curl ; Jellyfin s'il n'est pas installé (script officiel) | oui |
| `data` | le dossier de données (`SONALEX_DATA_DIR`) : `Musics/`, `logs/`, `temp/`, `config/` | oui |
| `python` | `backend/.venv` et les dépendances | non |
| `proxy` | Caddy dans `~/.local/bin`, Jellyfin déplacé sur un port interne | oui |
| `services` | les services systemd *utilisateur*, générés depuis `deploy/templates/` | non* |
| `check` | vérifie que tout répond | non |

`bash deploy/setup.sh services` ne refait qu'une étape. \* `services` demande sudo une seule
fois, pour `loginctl enable-linger` (les services démarrent au boot, sans session ouverte).

## Comment l'app trouve le serveur

L'app se connecte à l'adresse de Jellyfin et cherche le serveur Sonalex **à la même adresse,
sous `/sonalex/`**. Il faut donc un relais devant les deux :

```
app ──► :8096 ─┬─ /sonalex/*  ─► serveur Sonalex   127.0.0.1:8098
               └─ le reste     ─► Jellyfin          127.0.0.1:8097
```

### Option 1 : le relais Caddy du script (`SONALEX_PROXY=caddy`, par défaut)

Le script installe Caddy sur le port public (8096, celui de Jellyfin d'habitude) et déplace
Jellyfin sur 8097. L'adresse que tu donnes à l'app ne change pas. Ensuite, dans Jellyfin :
**Tableau de bord → Réseau → Proxies connus : `127.0.0.1`** (pour qu'il voie l'adresse réelle des
appareils).

Ports modifiables dans `backend/.env` : `SONALEX_PUBLIC_PORT`, `SONALEX_JELLYFIN_PORT`,
`SONALEX_SERVER_PORT`. Mets alors `SONALEX_JELLYFIN_URL=http://127.0.0.1:<SONALEX_JELLYFIN_PORT>`.

### Option 2 : ton propre reverse proxy (`SONALEX_PROXY=none`)

Jellyfin est déjà derrière nginx, Caddy ou Traefik (HTTPS, nom de domaine…) : ajoute une route
`/sonalex/` vers le serveur, **préfixe retiré**, WebSockets autorisés (Connect).

nginx :

```nginx
location /sonalex/ {
    proxy_pass http://127.0.0.1:8098/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;
    proxy_read_timeout 300s;
}
```

Caddy :

```caddy
jellyfin.exemple.fr {
	handle_path /sonalex/* {
		reverse_proxy 127.0.0.1:8098 {
			flush_interval -1
		}
	}
	reverse_proxy 127.0.0.1:8096
}
```

Garde alors Jellyfin sur son port habituel et `SONALEX_JELLYFIN_URL=http://127.0.0.1:8096`.

Pour vérifier : `curl https://jellyfin.exemple.fr/sonalex/api/health` doit répondre
`{"ok":true,"name":"Sonalex server",…}`.

## Services

| Service | Rôle |
|---|---|
| `sonalex-server` | le serveur (port 8098, 127.0.0.1 seulement) |
| `sonalex-proxy` | le relais Caddy (option 1) |
| `sonalex-sync.timer` | la synchro Spotify de minuit (si `SONALEX_SPOTIFY_SYNC=1`) |

```bash
systemctl --user status sonalex-server
journalctl --user -u sonalex-server -f      # ou : tail -f <données>/logs/server.log
systemctl --user restart sonalex-server     # après avoir modifié backend/.env
```

Les fichiers des services sont générés dans `~/.config/systemd/user/` à partir de
`deploy/templates/` : modifie les modèles, puis `bash deploy/setup.sh services`. Les anciens
services (`musique-api`, `musique-proxy`, `hosted-spotify-refresh`) sont remplacés automatiquement.

## Mettre à jour

```bash
git pull && bash deploy/setup.sh python && systemctl --user restart sonalex-server
```

## Revenir en arrière (relais Caddy)

1. Dans Jellyfin, **Tableau de bord → Réseau**, remettre le port HTTP local à **8096**, puis
   redémarrer Jellyfin.
2. `systemctl --user disable --now sonalex-proxy sonalex-server`
