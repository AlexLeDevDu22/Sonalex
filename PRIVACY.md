# Confidentialité – Sonalex

*Dernière mise à jour : 7 novembre 2026*

**En bref : Sonalex ne collecte aucune donnée.** Il n'y a ni compte Sonalex, ni publicité, ni
statistiques, ni traceur. L'app ne parle qu'aux serveurs que tu choisis.

## Ce qui reste sur ton appareil

- l'adresse de ton serveur et ton nom d'utilisateur, et le jeton de connexion que Jellyfin donne à l'app ;
- tes réglages, ta file d'attente et ton historique d'écoute (pour l'aléatoire intelligent) ;
- les sons et pochettes que tu télécharges, et un cache des pages déjà ouvertes.

Tout est supprimé si tu supprimes l'app. La déconnexion efface la session et la file d'attente.

## Ce qui part vers tes serveurs

- **Ton serveur Jellyfin** : ce que fait tout client Jellyfin (connexion, bibliothèque, lecture,
  favoris, playlists, morceaux écoutés pour l'historique et les statistiques de Jellyfin).
- **Le serveur Sonalex**, s'il est installé à côté de ton Jellyfin : les sons à préparer pour le Mix,
  l'état de lecture partagé entre tes appareils (Connect), et des informations techniques sur la
  lecture (événements du lecteur) qui aident à corriger les bugs. Ces données restent sur ce serveur.

Ces serveurs appartiennent à la personne qui les héberge (toi, ou quelqu'un qui t'a donné un
compte), pas au développeur de Sonalex : c'est elle qui en est responsable.

## Réseau local

Sur iPhone et iPad, l'app demande l'accès au réseau local pour joindre un serveur chez toi, et
pour trouver d'éventuelles lumières Ambilight à animer avec la musique.

## Contact

Pour toute question : une issue sur https://github.com/AlexLeDevDu22/sonalex/issues
