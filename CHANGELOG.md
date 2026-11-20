# Changelog

Store release notes live in [`docs/app-store/releases/`](docs/app-store/releases/).
Versions follow `MARKETING_VERSION` (build `CURRENT_PROJECT_VERSION`) in `ios/project.yml`.

## 1.1 (build 2) — CarPlay
- **CarPlay** audio interface: Recent, Playlists, Albums, Artists, Search, Favorites, and the
  system Now Playing with shuffle/repeat and Up Next. Needs Apple's `carplay-audio` entitlement
  to ship — see `docs/app-store/CARPLAY.md`.
- Playback no longer skips to another song when the connection drops (keeps and resumes the
  same track).
- Downloaded songs / offline mode load immediately; faster search; next cover prefetched.
- More reliable album/artist artwork loading.

## 1.0 (build 1) — First release
- Music player for a Jellyfin server: library, player, synced lyrics, queue, smart shuffle,
  gapless, downloads, AirPlay / lock screen / Dynamic Island, iPhone + iPad + Mac.
- Optional Sonalex server: Mix (DJ transitions) and Connect (multi-device).
