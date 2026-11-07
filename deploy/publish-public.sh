#!/usr/bin/env bash
# publish-public.sh – Makes a copy of the project with a fresh history, ready to push to a new
# *public* GitHub repository. The private history isn't published: old commits hold tokens.
#
#   bash deploy/publish-public.sh ~/sonalex-public
#   cd ~/sonalex-public && git remote add origin git@github.com:<toi>/sonalex.git && git push -u origin main
#
# Only what's committed goes in (git archive of HEAD), minus the personal files below.
set -euo pipefail

DEST="${1:?usage: bash deploy/publish-public.sh <empty folder>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The Pi's own files: the to-do list, and the services from before the new name (they point to
# its home folder; deploy/setup.sh replaces them, then they can go).
PERSONAL=(backend/todo.md backend/utils/redownload_song.py deploy/Caddyfile deploy/musique-api.service deploy/musique-proxy.service
          deploy/hosted-spotify-refresh.service deploy/hosted-spotify-refresh.timer)

[ ! -e "$DEST" ] || [ -z "$(ls -A "$DEST")" ] || { echo "$DEST isn't empty"; exit 1; }
mkdir -p "$DEST"
git -C "$REPO" archive --format=tar HEAD | tar -x -C "$DEST"
for f in "${PERSONAL[@]}"; do rm -f "$DEST/$f"; done

# Last check: nothing secret or personal made it in.
if grep -rIlE "playlist_analyzer_refresh_token\"\s*:\s*\"[A-Za-z0-9]|Token=\"[0-9a-f]{20,}|JELLYFIN_PW=.+" "$DEST" \
     --exclude=publish-public.sh --exclude=.env.example; then
  echo "The files above seem to hold secrets: nothing committed."
  exit 1
fi

cd "$DEST"
git init -q -b main
git add -A
git commit -q -m "Sonalex"
echo "Ready in $DEST ($(git ls-files | wc -l) files). Push it to a new public repository."
