# Privacy – Sonalex

*Last updated: November 7, 2026*

**In short: Sonalex collects no data.** There is no Sonalex account, no ads, no analytics and no
tracking. The app only talks to the servers you choose.

## What stays on your device

- your server's address, your username, and the sign-in token Jellyfin gives the app;
- your settings, your queue and your listening history (for smart shuffle);
- the songs and artwork you download, and a cache of pages you've already opened.

Everything is removed when you delete the app. Signing out clears the session and the queue.

## What goes to your servers

- **Your Jellyfin server**: what any Jellyfin client sends (sign-in, library, playback, favorites,
  playlists, played songs for Jellyfin's history and statistics).
- **The Sonalex server**, if one is installed next to your Jellyfin: the songs to prepare for the
  Mix, the playback state shared between your devices (Connect), and technical playback events that
  help fix bugs. This data stays on that server.

On a server with several users, the other users of **that server** see your profile: what you
listen to (and when), your top songs and artists, your song of the moment, your favorites count, and
which of their songs you have or like. You can hide yourself in the app (Profile → Music Service →
Show Me to Friends). If you connect a Spotify or Deezer account, its token or public profile is kept
on that server to sync your library.

These servers belong to whoever hosts them (you, or someone who gave you an account), not to the
developer of Sonalex: they are responsible for them.

## Local network

On iPhone and iPad, the app asks for local network access to reach a server at home, and to find
Ambilight lights to sync with the music.

## Contact

For any question, open an issue: https://github.com/AlexLeDevDu22/sonalex/issues
