#!/usr/bin/env bash
# setup.sh – Installs the Sonalex server next to Jellyfin, on Debian / Ubuntu / Raspberry Pi OS.
#
# Idempotent: run it as often as you like, it only does what's missing.
#
#   bash deploy/setup.sh            everything, in this order:
#   bash deploy/setup.sh packages   ffmpeg, python3-venv, curl, and Jellyfin if it isn't installed
#   bash deploy/setup.sh data       the data folder (music, state, logs, temp)
#   bash deploy/setup.sh python     backend/.venv with the Python dependencies
#   bash deploy/setup.sh proxy      Caddy, and Jellyfin moved behind it (SONALEX_PROXY=caddy)
#   bash deploy/setup.sh services   the systemd user services, from deploy/templates
#   bash deploy/setup.sh check      is everything answering?
#
# Settings: backend/.env (copied from backend/.env.example on the first run). The ones read here:
#   SONALEX_DATA_DIR       /srv/sonalex
#   SONALEX_PROXY          caddy = one public port for Jellyfin and the server (default),
#                          none  = you route /sonalex/* to the server in your own reverse proxy
#   SONALEX_PUBLIC_PORT    8096  the port the app connects to (Jellyfin's usual one)
#   SONALEX_JELLYFIN_PORT  8097  where Jellyfin moves to, behind Caddy
#   SONALEX_SERVER_PORT    8098  the Sonalex server, on 127.0.0.1 only
#   SONALEX_SPOTIFY_SYNC   1 = also install the nightly Spotify sync
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$REPO/backend"
TEMPLATES="$REPO/deploy/templates"
ENV_FILE="$BACKEND/.env"
UNIT_DIR="$HOME/.config/systemd/user"
CADDY="$HOME/.local/bin/caddy"
# Names of the services before the app was called Sonalex: replaced by the new ones.
OLD_UNITS=(musique-api.service musique-proxy.service hosted-spotify-refresh.service hosted-spotify-refresh.timer)

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

# A value of backend/.env (never `source`d: a password may hold characters the shell would read).
setting() {
  local value
  value=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" 2>/dev/null | tail -n1)
  value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
  printf '%s' "${value:-$2}"
}

load_settings() {
  if [ ! -f "$ENV_FILE" ]; then
    cp "$BACKEND/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    die "backend/.env créé depuis .env.example : remplis-le (compte Jellyfin au minimum), puis relance."
  fi
  DATA_DIR=$(setting SONALEX_DATA_DIR /srv/sonalex)
  PROXY=$(setting SONALEX_PROXY caddy)
  PUBLIC_PORT=$(setting SONALEX_PUBLIC_PORT 8096)
  JELLYFIN_PORT=$(setting SONALEX_JELLYFIN_PORT 8097)
  SERVER_PORT=$(setting SONALEX_SERVER_PORT 8098)
  case "$(setting SONALEX_SPOTIFY_SYNC 0)" in 1|true|yes|on) SPOTIFY_SYNC=1 ;; *) SPOTIFY_SYNC=0 ;; esac
  [ "$PROXY" = caddy ] || [ "$PROXY" = none ] || die "SONALEX_PROXY doit valoir caddy ou none (pas « $PROXY »)"
}

render() {  # template destination
  sed -e "s|@BACKEND@|$BACKEND|g" -e "s|@DATA_DIR@|$DATA_DIR|g" -e "s|@CADDY@|$CADDY|g" \
      -e "s|@PUBLIC_PORT@|$PUBLIC_PORT|g" -e "s|@JELLYFIN_PORT@|$JELLYFIN_PORT|g" \
      -e "s|@SERVER_PORT@|$SERVER_PORT|g" "$TEMPLATES/$1" > "$2"
}

do_packages() {
  step "Paquets système"
  local missing=() pkg
  for pkg in ffmpeg python3-venv python3-pip curl; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if ((${#missing[@]})); then
    sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
  fi
  ok "ffmpeg, python3-venv, curl"
  if ! command -v jellyfin >/dev/null 2>&1 && [ ! -x /usr/bin/jellyfin ]; then
    warn "Jellyfin absent : installation (script officiel de Jellyfin)"
    curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | sudo bash
  fi
  ok "Jellyfin installé"
}

do_data() {
  step "Dossier de données ($DATA_DIR)"
  sudo mkdir -p "$DATA_DIR"/{Musics,logs,temp/stream,config}
  sudo chown "$USER":"$USER" "$DATA_DIR" "$DATA_DIR"/{logs,temp,temp/stream,config}
  [ -O "$DATA_DIR/Musics" ] || sudo chown "$USER":"$USER" "$DATA_DIR/Musics"
  # Jellyfin must be able to read the music.
  chmod o+rX "$DATA_DIR" "$DATA_DIR/Musics"
  local f
  for f in tracks.json playlists.json; do
    [ -f "$DATA_DIR/$f" ] || echo '{}' > "$DATA_DIR/$f"
  done
  ok "Musics, logs, temp, config"
  echo "  Dans Jellyfin, ajoute une bibliothèque Musique sur $DATA_DIR/Musics (ou garde la tienne)."
}

do_python() {
  step "Environnement Python (backend/.venv)"
  [ -d "$BACKEND/.venv" ] || python3 -m venv "$BACKEND/.venv"
  "$BACKEND/.venv/bin/pip" install -q --upgrade pip
  "$BACKEND/.venv/bin/pip" install -q -r "$BACKEND/requirements.txt"
  ok "dépendances installées"
  if [ "$SPOTIFY_SYNC" = 1 ] && [ ! -f "$BACKEND/chosic_data.json" ]; then
    warn "synchro Spotify activée mais backend/chosic_data.json manquant (voir backend/README.md)"
  fi
}

do_proxy() {
  if [ "$PROXY" != caddy ]; then
    step "Relais : géré par toi (SONALEX_PROXY=none)"
    echo "  Route /sonalex/* (préfixe retiré) vers http://127.0.0.1:$SERVER_PORT, le reste vers Jellyfin."
    echo "  Exemples nginx / Caddy : deploy/README.md."
    return
  fi
  step "Caddy ($CADDY)"
  if [ ! -x "$CADDY" ]; then
    mkdir -p "$(dirname "$CADDY")"
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$(dpkg --print-architecture)" -o "$CADDY"
    chmod +x "$CADDY"
  fi
  ok "$("$CADDY" version | cut -d' ' -f1)"

  step "Jellyfin sur le port interne $JELLYFIN_PORT (Caddy prend le $PUBLIC_PORT)"
  local net=/etc/jellyfin/network.xml
  if sudo test -f "$net"; then
    if ! sudo grep -q "<InternalHttpPort>$JELLYFIN_PORT</InternalHttpPort>" "$net"; then
      sudo sed -i "s|<InternalHttpPort>[0-9]*</InternalHttpPort>|<InternalHttpPort>$JELLYFIN_PORT</InternalHttpPort>|" "$net"
      sudo systemctl restart jellyfin
      ok "port passé à $JELLYFIN_PORT, Jellyfin redémarré"
    else
      ok "déjà sur $JELLYFIN_PORT"
    fi
    sudo grep -q "<string>127.0.0.1</string>" "$net" \
      || warn "Jellyfin → Tableau de bord → Réseau : ajoute 127.0.0.1 aux « Proxies connus »"
  else
    warn "$net absent : lance Jellyfin une fois (http://<serveur>:8096), fais l'assistant, puis relance ce script"
  fi
  sudo systemctl enable --now jellyfin >/dev/null 2>&1 || true
}

do_services() {
  step "Services utilisateur (systemd)"
  # Without "linger", user services only start once you log in; with it, at boot.
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]; then
    sudo loginctl enable-linger "$USER"
  fi
  mkdir -p "$UNIT_DIR" "$DATA_DIR/config" "$DATA_DIR/logs"
  local unit
  for unit in "${OLD_UNITS[@]}"; do
    if [ -e "$UNIT_DIR/$unit" ] || [ -L "$UNIT_DIR/$unit" ]; then
      systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
      rm -f "$UNIT_DIR/$unit"
      ok "ancien service $unit retiré"
    fi
  done

  local units=(sonalex-server.service)
  render sonalex-server.service "$UNIT_DIR/sonalex-server.service"
  if [ "$PROXY" = caddy ]; then
    render Caddyfile "$DATA_DIR/config/Caddyfile"
    "$CADDY" validate --config "$DATA_DIR/config/Caddyfile" --adapter caddyfile >/dev/null 2>&1 \
      || die "Caddyfile invalide : $DATA_DIR/config/Caddyfile"
    render sonalex-proxy.service "$UNIT_DIR/sonalex-proxy.service"
    units+=(sonalex-proxy.service)
  else
    systemctl --user disable --now sonalex-proxy.service >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/sonalex-proxy.service"
  fi
  if [ "$SPOTIFY_SYNC" = 1 ]; then
    render sonalex-sync.service "$UNIT_DIR/sonalex-sync.service"
    render sonalex-sync.timer "$UNIT_DIR/sonalex-sync.timer"
    units+=(sonalex-sync.timer)
  else
    systemctl --user disable --now sonalex-sync.timer >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR"/sonalex-sync.{service,timer}
  fi
  systemctl --user daemon-reload
  systemctl --user enable "${units[@]}" >/dev/null
  for unit in "${units[@]}"; do
    [[ "$unit" == *.timer ]] && systemctl --user start "$unit" || systemctl --user restart "$unit"
  done
  ok "${units[*]}"
}

do_check() {
  step "Vérifications"
  sleep 6
  check() {  # name url
    if curl -fsS -o /dev/null --max-time 10 "$2"; then ok "$1"; else warn "$1 ne répond pas ($2)"; fi
  }
  check "Sonalex server ($SERVER_PORT)" "http://127.0.0.1:$SERVER_PORT/api/health"
  if [ "$PROXY" = caddy ]; then
    check "Jellyfin ($JELLYFIN_PORT)" "http://127.0.0.1:$JELLYFIN_PORT/System/Info/Public"
    check "Adresse publique ($PUBLIC_PORT → Jellyfin)" "http://127.0.0.1:$PUBLIC_PORT/System/Info/Public"
    check "Adresse publique ($PUBLIC_PORT → Sonalex)" "http://127.0.0.1:$PUBLIC_PORT/sonalex/api/health"
  fi
  if [ "$SPOTIFY_SYNC" = 1 ]; then
    systemctl --user list-timers sonalex-sync.timer --no-pager | sed -n 2p | sed 's/^/  prochaine synchro : /'
  fi
  cat <<MSG

Dans l'app Sonalex, connecte-toi avec l'adresse de Jellyfin (http://<serveur>:$PUBLIC_PORT, ou ton
nom de domaine) : l'app trouve le serveur Sonalex toute seule à côté.
Journaux : $DATA_DIR/logs/ · état : systemctl --user status sonalex-server
MSG
}

load_settings
case "${1:-all}" in
  packages) do_packages ;;
  data) do_data ;;
  python) do_python ;;
  proxy) do_proxy ;;
  services) do_services ;;
  check) do_check ;;
  all) do_packages; do_data; do_python; do_proxy; do_services; do_check ;;
  *) die "étape inconnue : $1 (packages, data, python, proxy, services, check, all)" ;;
esac
