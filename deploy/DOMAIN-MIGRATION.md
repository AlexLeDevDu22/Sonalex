# Public domain → `my-sonalex.garinio.com`  (done 2026-11-20)

The app, the Sonalex server and Jellyfin are served on **`my-sonalex.garinio.com`**, while
**`sonalex.garinio.com`** keeps working (already-installed apps saved that address).

## What actually happened

`my-sonalex.garinio.com` → `86.203.251.51` (home) → the Pi **directly**. Home forwards
:80/:443 to the Pi, so Let's Encrypt validated it and Caddy issued a cert — **no relay needed**
for `my-sonalex`. (`sonalex.garinio.com` still goes through the OVH relay `158.69.194.254`;
left as-is so old apps don't break.)

The `SSL_ERROR_INTERNAL_ERROR_ALERT` in the browser was only because Caddy wasn't serving
`my-sonalex` yet (no site / no cert for that SNI → TLS rejected). Fixed by adding it to the
Caddyfile and restarting the proxy.

## Done on the Pi
- `/srv/sonalex/config/Caddyfile` → `my-sonalex.garinio.com, sonalex.garinio.com { … }`,
  validated, applied (`systemctl --user restart sonalex-proxy`). Cert for `my-sonalex`
  obtained ✅. Both domains return HTTP 200 with a valid cert.
- `backend/.env` → `SONALEX_DOMAIN=my-sonalex.garinio.com, sonalex.garinio.com` (so a future
  `bash deploy/setup.sh proxy` regenerates the same two-domain block).

## One step left — you (needs sudo, local Wi-Fi only)

So `my-sonalex` is fast at home and dodges Orange's hairpin NAT, add it to the local
split-horizon DNS, next to the existing `sonalex` line:

```bash
echo 'address=/my-sonalex.garinio.com/192.168.1.34' | sudo tee -a /etc/dnsmasq.d/sonalex.conf
sudo systemctl restart dnsmasq
```

Verify (on the Pi): `getent hosts my-sonalex.garinio.com` → `192.168.1.34`.

External access and the certificate already work **without** this — it only improves
in-home Wi-Fi access.

## Verify from outside
```bash
# Phone on cellular (Wi-Fi off), or any external host:
curl -I https://my-sonalex.garinio.com/sonalex/     # HTTP 200, valid TLS
```
Then sign in on a device with `https://my-sonalex.garinio.com` and play a song.
