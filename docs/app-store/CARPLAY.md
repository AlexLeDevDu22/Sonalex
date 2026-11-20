# CarPlay

Sonalex has a full CarPlay audio interface: a tab bar (**Recent · Playlists · Albums ·
Artists**), **Search**, a **Favorites** shortcut, and the system **Now Playing** screen
with shuffle / repeat and an **Up Next** list. It drives the same `PlayerManager` as the
phone, so whatever plays in the car is the same session.

Files:
- `ios/Sonalex/CarPlay/CarPlayController.swift` — the whole CarPlay UI (`CarPlaySceneDelegate`).
- `ios/Sonalex/Info.plist` + `ios/project.yml` — declares the CarPlay scene.
- `ios/Sonalex/Sonalex-carplay.entitlements` — the CarPlay audio entitlement.

## ⚠️ You can't ship CarPlay without Apple's approval

A CarPlay **audio** app needs the entitlement **`com.apple.developer.carplay-audio`**.
Apple grants it **by request**, not in the normal capabilities list:

> Request it here: https://developer.apple.com/contact/request/carplay-audio
> (Pick "CarPlay audio app". Review can take days to a few weeks.)

Until Apple approves it for your App ID:
- **Simulator**: works now (the simulator doesn't check entitlements).
- **Real car / device / App Store build**: code signing **fails** — the entitlement isn't
  in your provisioning profile.

So the plan is:
1. **Ship 1.0 now, without CarPlay.** The code is already in the project but dormant: the
   CarPlay scene just never connects without the entitlement, so it's safe in the build.
2. **Request the entitlement** (link above).
3. When granted: enable it on the App ID (Certificates, IDs & Profiles → your App ID →
   CarPlay audio), regenerate the profile, point the build at the entitlements file (below),
   and ship **1.1** with CarPlay.

## Test it now in the Simulator (no approval needed)

1. In `ios/project.yml`, under the `Sonalex` target `settings: base:`, temporarily add:
   ```yaml
   CODE_SIGN_ENTITLEMENTS: Sonalex/Sonalex-carplay.entitlements
   ```
   (or set it in Xcode: target → Build Settings → *Code Signing Entitlements* →
   `Sonalex/Sonalex-carplay.entitlements`). Regenerate with `xcodegen` if you edited the yml.
   > Remove this again for the App Store archive until Apple has approved the entitlement,
   > or distribution signing will fail.
2. Run the app on an **iPhone simulator** and sign in to your server.
3. In the simulator menu: **I/O → External Displays → CarPlay**. A CarPlay window opens.
4. You should see the Sonalex tabs. Play something — Now Playing appears, and the phone and
   the car stay in sync.

## When it's approved — ship it

- Enable **CarPlay audio** on the App ID, regenerate profiles.
- Set `CODE_SIGN_ENTITLEMENTS: Sonalex/Sonalex-carplay.entitlements` for the real build
  (both configs), `xcodegen`, archive, submit.
- App Review for CarPlay uses the same demo account as the rest (see
  `submission/review-notes.txt`); mention in the notes that the app supports CarPlay and
  how you tested it.

## Design notes (why it looks the way it does)

CarPlay is template-only for driver safety: a handful of list levels, short lists, large
tap targets, no custom layout. The interface mirrors the app's structure (Recent, your
library, favorites, search) so it feels like the same app, and leans on the system Now
Playing screen — which is already fed by `MPNowPlayingInfoCenter` — instead of a custom one.
