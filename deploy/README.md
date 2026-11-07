# Installing the Sonalex server

The Sonalex server goes **on the machine that runs Jellyfin** (it reads the library's files to
prepare the Mix). Tested on Raspberry Pi OS (Debian 13) with Jellyfin 12; any recent Debian /
Ubuntu works.

## Install

```bash
git clone https://github.com/AlexLeDevDu22/sonalex.git && cd sonalex
bash deploy/setup.sh
```

The first run creates `backend/.env` from `backend/.env.example` and stops: fill in at least the
Jellyfin address and an **administrator** account (the server needs it to know where the files
are), then run `bash deploy/setup.sh` again.

The script is idempotent (run it as often as you like) and split into steps:

| Step | What it does | sudo |
|---|---|---|
| `packages` | ffmpeg, python3-venv, curl; Jellyfin if it isn't installed (official script) | yes |
| `data` | the data folder (`SONALEX_DATA_DIR`): `Musics/`, `logs/`, `temp/`, `config/` | yes |
| `python` | `backend/.venv` and the dependencies | no |
| `proxy` | Caddy in `~/.local/bin`, Jellyfin moved to an internal port | yes |
| `services` | the systemd *user* services, generated from `deploy/templates/` | no* |
| `check` | checks that everything answers | no |

`bash deploy/setup.sh services` runs a single step. \* `services` asks for sudo once, for
`loginctl enable-linger` (the services then start at boot, without a logged-in session).

## How the app finds the server

The app connects to the Jellyfin address and looks for the Sonalex server **at the same address,
under `/sonalex/`**. So both need a relay in front of them:

```
app ──► :8096 ─┬─ /sonalex/*  ─► Sonalex server   127.0.0.1:8098
               └─ the rest     ─► Jellyfin         127.0.0.1:8097
```

### Option 1: the script's Caddy relay (`SONALEX_PROXY=caddy`, the default)

The script puts Caddy on the public port (8096, Jellyfin's usual one) and moves Jellyfin to 8097.
The address you give the app doesn't change. Then, in Jellyfin: **Dashboard → Networking → Known
proxies: `127.0.0.1`** (so it sees the devices' real addresses).

Ports can be changed in `backend/.env`: `SONALEX_PUBLIC_PORT`, `SONALEX_JELLYFIN_PORT`,
`SONALEX_SERVER_PORT`. Then set `SONALEX_JELLYFIN_URL=http://127.0.0.1:<SONALEX_JELLYFIN_PORT>`.

### Option 2: your own reverse proxy (`SONALEX_PROXY=none`)

Jellyfin is already behind nginx, Caddy or Traefik (HTTPS, a domain name…): add a `/sonalex/` route
to the server, **prefix stripped**, with WebSockets allowed (Connect).

nginx:

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

Caddy:

```caddy
jellyfin.example.com {
	handle_path /sonalex/* {
		reverse_proxy 127.0.0.1:8098 {
			flush_interval -1
		}
	}
	reverse_proxy 127.0.0.1:8096
}
```

Keep Jellyfin on its usual port and `SONALEX_JELLYFIN_URL=http://127.0.0.1:8096`.

To check: `curl https://jellyfin.example.com/sonalex/api/health` must answer
`{"ok":true,"name":"Sonalex server",…}`.

## Services

| Service | Role |
|---|---|
| `sonalex-server` | the server (port 8098, 127.0.0.1 only) |
| `sonalex-proxy` | the Caddy relay (option 1) |
| `sonalex-sync.timer` | the midnight Spotify sync (if `SONALEX_SPOTIFY_SYNC=1`) |

```bash
systemctl --user status sonalex-server
journalctl --user -u sonalex-server -f      # or: tail -f <data>/logs/server.log
systemctl --user restart sonalex-server     # after changing backend/.env
```

The service files are generated in `~/.config/systemd/user/` from `deploy/templates/`: edit the
templates, then `bash deploy/setup.sh services`. Services from before the app was renamed
(`musique-api`, `musique-proxy`, `hosted-spotify-refresh`) are replaced automatically.

## Updating

```bash
git pull && bash deploy/setup.sh python && systemctl --user restart sonalex-server
```

## Undoing the Caddy relay

1. In Jellyfin, **Dashboard → Networking**, set the local HTTP port back to **8096**, then restart
   Jellyfin.
2. `systemctl --user disable --now sonalex-proxy sonalex-server`
