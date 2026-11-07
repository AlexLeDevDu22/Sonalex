# Sonalex — l'app (SwiftUI, iPhone, iPad, Mac)

App native qui lit la bibliothèque musicale d'un serveur Jellyfin : accueil, nouveautés,
bibliothèque, recherche, lecteur plein écran avec paroles synchronisées, file d'attente,
téléchargements hors connexion, AirPlay, écran verrouillé, Dynamic Island, et une vraie app Mac
(Mac Catalyst) avec barre latérale et icône dans la barre des menus.

Avec le [serveur Sonalex](../backend/README.md) à côté de Jellyfin : Mix (transitions de DJ) et
Connect (un appareil joue, les autres le pilotent). L'app le détecte toute seule
(`ServerFeatures`, `GET <jellyfin>/sonalex/api/health`) et n'affiche que ce qu'il propose.

## Compiler

Prérequis : un Mac avec **Xcode 26** ou plus récent, iOS 18+ sur l'appareil, et
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd ios && xcodegen && open Sonalex.xcodeproj
```

1. **Xcode → Réglages → Comptes → +** : ajoute ton Apple ID.
2. Cible **Sonalex → Signing & Capabilities** : choisis ton équipe. L'identifiant
   `com.alexgarin.sonalex` est déjà pris : remplace le préfixe `com.alexgarin` dans `project.yml`
   (`bundleIdPrefix` et les deux `PRODUCT_BUNDLE_IDENTIFIER`), puis relance `xcodegen`.
3. iPhone branché, **mode développeur** activé (Réglages → Confidentialité et sécurité), puis ▶.
   La première fois : **Réglages → Général → VPN et gestion de l'appareil → Faire confiance**.

> Avec un Apple ID gratuit, l'app **expire au bout de 7 jours** : relance ▶ depuis Xcode.

`Sonalex.xcodeproj` est généré à partir de `project.yml` et n'est pas versionné : relance
`xcodegen` après avoir ajouté ou supprimé des fichiers.

## Sur le Mac

Destination **My Mac (Mac Catalyst)** puis ▶. Après chaque compilation Mac, l'app est installée
dans **Applications** et déclarée pour les liens `sonalex://` (`scripts/install-mac-app.sh`).

- Raccourcis : espace, ⌘← / ⌘→, ⌘S (aléatoire), ⌘R (répétition), ⇧⌘L (en lecture).
- Pilotable par d'autres apps (Atoll…) : `open -g "sonalex://pause"` (`musique://` marche aussi),
  ou un fichier de commande + une notification Darwin : [`docs/now-playing-mac.md`](../docs/now-playing-mac.md).
- **Version App Store** : la configuration *Release* active l'App Sandbox
  (`Sonalex/Sonalex-mac.entitlements`), obligatoire sur le Mac App Store. Dans le bac à sable,
  `NowPlaying.json` est écrit dans le conteneur de l'app ; les compilations *Debug* gardent le
  dossier habituel.

Le schéma `sonalex://` est déclaré dans `project.yml` et dans `Sonalex/Info.plist`, généré par
`xcodegen` et commité : les deux doivent rester identiques (la build échoue sinon).

## Architecture

| Dossier | Contenu |
|---|---|
| `Sonalex/API` | `JellyfinClient` (REST Jellyfin), `SonalexAPI` + `ServerFeatures` (serveur Sonalex), `ResponseCache` (cache disque des réponses), modèles, session |
| `Sonalex/Player` | `PlayerManager` (`AVQueuePlayer`, enchaînement sans blanc, arrière-plan, écran verrouillé, file persistée), `MixEngine` (AVAudioEngine : les morceaux du Mix bout à bout), `ConnectManager`, `OfflineStore` (téléchargements), `NowPlayingExport` (Mac) |
| `Sonalex/App` | point d'entrée, onglets (iPhone) et fenêtre Mac, routage, stores (favoris, images, toasts), `AppInfo` |
| `Sonalex/Ambilight` | lumières Ambilight d'un Mac du réseau : découverte Bonjour, appairage, son joué envoyé en temps réel |
| `Sonalex/Views` | les écrans |
| `SonalexMenuBar` | l'icône de la barre des menus du Mac (plug-in AppKit, chargé par l'app Catalyst) |
| `Sonalex/Resources` | icônes, couleur d'accent, `PrivacyInfo.xcprivacy` |
