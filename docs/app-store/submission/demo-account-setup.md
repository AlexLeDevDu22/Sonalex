# Demo account for Apple review — MUST be set up before submitting

Apple's reviewer signs in to **your** server. If the login below doesn't work, or the
library is empty, the app is rejected ("app not functional", guideline 2.1).

I **generated** these credentials, but I did **not** create the account on your server
(that requires admin access to Jellyfin, and the reviewer must only see a safe demo
library — that's your call). Create this exact user yourself, in the Jellyfin dashboard:

```
Server:   https://my-sonalex.garinio.com
Username: review
Password: Sonalex-Review-IEBc1
```

## Steps (Jellyfin Dashboard → Users)

1. **Check the server is reachable from the public Internet over HTTPS.**
   From a phone on cellular (Wi-Fi off), open https://my-sonalex.garinio.com — the
   Jellyfin / Sonalex page must load. If it only works at home, Apple can't reach it.

2. **Create a demo library with royalty-free music only.**
   No commercial album artwork or copyrighted tracks (that alone can get the app
   rejected, and it's your server's copyright exposure). Use Creative Commons music,
   e.g. Free Music Archive (https://freemusicarchive.org) or Jamendo.

3. **Create the user** `review` with the password above
   (Dashboard → Users → + ). Give it a strong password — this one is fine.

4. **Restrict what `review` can see**: on the user's **Access** tab, untick
   "Enable access to all libraries" and allow **only** the demo library.
   Do not give it admin rights.

5. **Turn OFF the online catalog for the demo.**
   In `backend/.env`, make sure `SONALEX_ONLINE` is **not** set to 1 (downloading from
   YouTube / using the Spotify catalog breaks App Store guidelines 5.2.2 / 5.2.3).

6. **Test the login yourself** in the app (or the web app at the URL above) with
   `review` / the password, from OUTSIDE your home network, and confirm a song plays.

Once that works, paste `review-notes.txt` into App Store Connect and submit.

> Note: you wrote the server is `https://my-sonalex.garinio.com`. Double-check that's the
> public domain that actually answers (earlier the stack was on `sonalex.garinio.com`).
> Whatever the reviewer types in the app must match this exactly.
