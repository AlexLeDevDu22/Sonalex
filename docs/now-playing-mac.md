# Musique (Mac) → « en lecture » et choix d'appareil pour une autre app (ex. Atoll)

**Musique** tourne sur l'iPhone et sur le Mac (Mac Catalyst). Grâce à **Musique Connect**, un seul
appareil joue le son à la fois ; les autres reflètent ce qu'il joue et le pilotent. Sur le Mac,
l'app publie donc **toujours ce qui joue sur n'importe lequel des appareils**, et accepte des
commandes qu'elle exécute ou transmet à l'appareil qui joue.

Une app comme **Atoll** n'a besoin de parler qu'à l'app Mac :

| Atoll veut… | Comment |
|---|---|
| savoir ce qui joue (titre, pochette, position), même sur l'iPhone | lire `NowPlaying.json` à chaque notification Darwin (§2) |
| lecture / pause / suivant / précédent, même si c'est l'iPhone qui joue | ouvrir `sonalex://…` (§3) |
| afficher les appareils (Mac, iPhone) et lequel joue | bloc `connect` du JSON (§2) |
| faire jouer sur le Mac ou sur l'iPhone | `sonalex://transfer?device=<id>` (§3) |

---

## 1. Le « En lecture » standard de macOS

L'app Mac renseigne `MPNowPlayingInfoCenter` (titre, artiste, album, pochette, durée, position,
vitesse) et `playbackState`, y compris quand c'est l'iPhone qui joue. Elle répond aussi aux
commandes système : touches média, Centre de contrôle, `MRMediaRemoteSendCommand`. Ces commandes
sont transmises à l'appareil qui joue.

Une app qui lit le Now Playing système via MediaRemote (depuis macOS 15.4, par un adaptateur comme
[`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter)) voit donc Musique. Mais ce
canal ne permet **pas** de choisir l'appareil : pour ça, il faut le §2 et le §3.

## 2. `NowPlaying.json` + notification Darwin

À chaque changement (morceau, lecture/pause, saut, appareil qui joue, appareil connecté ou
déconnecté) et toutes les ~5 s pendant la lecture, l'app Mac réécrit **atomiquement** :

```
~/Library/Application Support/Musique/NowPlaying.json
```

Juste après, elle poste la **notification Darwin** `com.alexgarin.musique.nowplaying`.

```json
{
  "title": "TORE UP",
  "artist": "Don Toliver",
  "album": "HARDSTONE PSYCHO",
  "artworkURL": "https://jellyfin.exemple.fr/Items/fc41e7…/Images/Primary?fillWidth=600&fillHeight=600&quality=90&tag=…",
  "duration": 127.0,
  "elapsed": 42.3,
  "isPlaying": true,
  "source": "library",
  "id": "6da3d3585a7d641ee9c4a8386b8e8159",
  "updatedAt": 1790950000.12,
  "bundleId": "maccatalyst.com.alexgarin.sonalex",
  "connect": {
    "available": true,
    "thisDevice": "6F1C…-MAC",
    "playingOn": "A93B…-IPHONE",
    "isRemote": true,
    "devices": [
      { "id": "6F1C…-MAC",    "name": "MacBook Air"        , "kind": "mac",   "isThisDevice": true,  "isPlaying": false },
      { "id": "A93B…-IPHONE", "name": "iPhone",              "kind": "phone", "isThisDevice": false, "isPlaying": true }
    ]
  }
}
```

| Champ | Description |
|---|---|
| `title`, `artist`, `album` | Ce qui joue, sur ce Mac **ou sur l'appareil qui joue**. Absents si rien n'est chargé. |
| `artworkURL` | JPEG (Jellyfin ou CDN Spotify), téléchargeable sans authentification. |
| `duration`, `elapsed` | En secondes. Position réelle = `elapsed + (now - updatedAt)` si `isPlaying`. |
| `isPlaying` | Lecture voulue (ici ou sur l'appareil qui joue) : reste `true` pendant un chargement ou un changement de sortie audio, `false` seulement après une vraie pause, la fin de la file ou une erreur. |
| `source` | `"library"` (Jellyfin) ou `"online"` (titre en ligne streamé par le Pi). |
| `id` | Identifiant du morceau ; il change à chaque nouveau titre. |
| `connect.available` | L'app Mac est reliée au Pi. Si `false`, la liste d'appareils est vide. |
| `connect.thisDevice` | Identifiant du Mac lui-même. |
| `connect.playingOn` | Identifiant de l'appareil qui joue. Vide si rien ne joue nulle part. |
| `connect.isRemote` | `true` si un **autre** appareil que le Mac joue. |
| `connect.devices` | Appareils connectés : `id`, `name` (ex. « iPhone de Léa », modifiable dans l'app : profil → Nom de cet appareil), `kind` (`mac`, `phone`, `tablet`), `volume` (0…1, volume de lecture de l'app sur cet appareil), `isThisDevice`, `isPlaying`. |

Si `updatedAt` a plus de 10 s alors que `isPlaying` vaut `true`, l'app Mac est fermée : il n'y a
plus de source Musique.

## 3. Commandes : `sonalex://`

`musique://…` (le nom d'avant) marche toujours. Le dossier `~/Library/Application Support/Musique/`
n'a pas changé de nom ; dans la version App Store (bac à sable), il est dans le conteneur de l'app :
`~/Library/Containers/com.alexgarin.sonalex/Data/Library/Application Support/Musique/`.

| URL | Effet |
|---|---|
| `sonalex://playpause` | lecture / pause (sur l'appareil qui joue) |
| `sonalex://play`, `sonalex://pause` | lecture, pause |
| `sonalex://next`, `sonalex://previous` | morceau suivant / précédent |
| `sonalex://open` | affiche l'écran « En lecture » de l'app Mac |
| `sonalex://transfer?device=<id>` | fait jouer sur l'appareil `<id>`, pris dans `connect.devices` |
| `sonalex://volume?level=0.42` | volume de lecture (0…1) de l'appareil qui joue, transmis s'il s'agit d'un autre ; conservé lors d'un transfert |
| `sonalex://transfer?device=this` | fait jouer sur ce Mac |
| `sonalex://transfer?kind=phone` | fait jouer sur l'iPhone (le premier appareil `phone`) ; `kind=mac` pour le Mac |

Le transfert reprend **au même endroit du même morceau**, avec la même file d'attente. L'appareil
qui jouait s'arrête. Le JSON est réécrit dès que le Pi confirme (quelques dixièmes de seconde).

Ouvre ces URL **sans mettre Musique au premier plan** :

```swift
func musique(_ command: String) {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    NSWorkspace.shared.open(URL(string: "sonalex://\(command)")!, configuration: config)
}
musique("next")
musique("transfer?kind=phone")
```

### 3 bis. Commandes sans URL (recommandé pour Atoll)

Les URL `sonalex://` dépendent de macOS, qui doit savoir quelle app les ouvre. Avec une app de
développement, il l'oublie parfois (« There is no application set to open the URL »). Le canal
suivant passe directement par l'app Mac, quand elle est ouverte :

1. Écrire `~/Library/Application Support/Musique/Command.json` :
   ```json
   { "id": "<identifiant unique, ex. UUID>", "command": "pause" }
   ```
   `command` accepte `play`, `pause`, `playpause`, `next`, `previous`, `open`,
   `volume` (avec `"level": 0.42`) et `transfer` (avec `"device": "<id>"` ou `"this"`, ou
   `"kind": "phone"`). L'`id` doit changer à chaque commande, sinon elle est ignorée.
2. Poster la notification Darwin `com.alexgarin.musique.command`.

```swift
func musiqueCommand(_ command: String, extra: [String: Any] = [:]) {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Musique/Command.json")
    var body = extra
    body["id"] = UUID().uuidString
    body["command"] = command
    if let data = try? JSONSerialization.data(withJSONObject: body) {
        try? data.write(to: url, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.alexgarin.musique.command" as CFString), nil, nil, true)
    }
}
musiqueCommand("pause")
musiqueCommand("volume", extra: ["level": 0.42])
musiqueCommand("transfer", extra: ["kind": "phone"])
```

Conseil : utiliser ce canal quand l'app Mac tourne (le `updatedAt` du JSON est récent), et les URL
`sonalex://` seulement pour lancer l'app quand elle est fermée.

## 4. Lecture côté Atoll (Swift)

```swift
import AppKit

struct MusiqueDevice: Decodable, Identifiable {
    let id: String; let name: String; let kind: String
    let isThisDevice: Bool; let isPlaying: Bool
}

struct MusiqueNowPlaying: Decodable {
    struct Connect: Decodable {
        let available: Bool; let thisDevice: String; let playingOn: String
        let isRemote: Bool; let devices: [MusiqueDevice]
    }
    let title: String?; let artist: String?; let album: String?
    let artworkURL: String?; let duration: Double; let elapsed: Double
    let isPlaying: Bool; let updatedAt: Double; let id: String?
    let connect: Connect?

    /// Current position, moved forward since the last write.
    var position: Double {
        isPlaying ? min(duration, elapsed + Date().timeIntervalSince1970 - updatedAt) : elapsed
    }
}

final class MusiqueSource {
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Musique/NowPlaying.json")
    var onChange: ((MusiqueNowPlaying) -> Void)?

    func start() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<MusiqueSource>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.reload() }
            },
            "com.alexgarin.musique.nowplaying" as CFString, nil, .deliverImmediately)
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(MusiqueNowPlaying.self, from: data) else { return }
        onChange?(info)
    }

    func send(_ command: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(URL(string: "sonalex://\(command)")!, configuration: config)
    }

    func play(on device: MusiqueDevice) { send("transfer?device=\(device.id)") }
}
```

## 5. Le bouton « appareil » dans Atoll

- Ne l'affiche que si `connect.available` vaut `true` et que `connect.devices` contient au moins
  2 appareils.
- **Icône** (SF Symbols) selon l'appareil qui joue (`isPlaying == true`) : `laptopcomputer` pour
  `mac`, `iphone` pour `phone`, `ipad` pour `tablet`. Mets-la en couleur d'accent si
  `connect.isRemote` (le son sort de l'iPhone, pas du Mac).
- **Au clic**, un menu liste `connect.devices` : nom (« Ce Mac » si `isThisDevice`), coche sur
  celui qui joue. Choisir une ligne envoie `sonalex://transfer?device=<id>`.
- **Raccourci** possible : un simple bascule Mac ↔ iPhone qui envoie `transfer?kind=phone` si le
  Mac joue, `transfer?device=this` sinon.

---

## Consigne à donner à une session Claude sur le Mac (pour Atoll)

> Atoll est une app open source « Dynamic Island » pour Mac. Son contrôleur média gère Spotify.
> Ajoute une source **Musique** (mon lecteur Jellyfin, synchronisé entre mon Mac et mon iPhone)
> en suivant `docs/now-playing-mac.md` du dépôt hosted-spotify :
> 1. Lire `~/Library/Application Support/Musique/NowPlaying.json` au démarrage et à chaque
>    notification Darwin `com.alexgarin.musique.nowplaying`. Interpoler la position avec
>    `elapsed + (maintenant - updatedAt)` pendant la lecture.
> 2. Afficher le titre, l'artiste, la pochette (`artworkURL`) et la progression comme pour
>    Spotify, **même quand le son sort de l'iPhone** (`connect.isRemote`).
> 3. Envoyer les commandes par `Command.json` + la notification Darwin
>    `com.alexgarin.musique.command` (§3 bis) quand l'app Mac tourne ; les URL `sonalex://` seulement
>    pour la lancer si elle est fermée.
> 4. Ajouter un **bouton appareil** (§5) : un menu des `connect.devices` avec une coche sur celui
>    qui joue ; un choix envoie `sonalex://transfer?device=<id>`.
> 5. Donner la priorité à Musique quand `isPlaying` vaut `true` ; sinon revenir à la source
>    précédente (Spotify). Considérer la source absente si `updatedAt` a plus de 10 s pendant la
>    lecture.
> Respecte l'architecture existante d'Atoll (même protocole et même interface que le contrôleur
> Spotify).
