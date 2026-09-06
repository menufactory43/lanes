# Jalons — Lanes

Lanes est un tableau de bord Git en lecture seule pour macOS, conçu autour d'un
budget de lancement : interactif avec toutes ses données en moins d'une seconde
à froid (« half bounce » : l'icône du Dock n'a pas fini son premier rebond).

| # | Jalon | Livrable vérifiable | État |
|---|-------|---------------------|------|
| M1 | Squelette | Bundle `.app` construit par script, fenêtre à l'écran, métriques de lancement (`LANES_MEASURE=1`) imprimées | ✅ |
| M2 | Snapshot | Format binaire versionné, writer + reader `mmap`, tests d'aller-retour et de corruption | ✅ |
| M3 | Extraction | `git` CLI → snapshot complet (commits, refs, auteurs, fichiers chauds, santé), layout des voies, tests sur dépôt temporaire | ✅ |
| M4 | Dashboard | Tous les widgets sur données réelles, graphe virtualisé à 75 000 commits fluide | ✅ |
| M5 | Synchronisation | Empreinte du dépôt, FSEvents, reconstruction incrémentale, « depuis ta dernière visite », ouverture/récents/glisser-déposer | ✅ |
| M6 | Finition | Icône, apparition de fenêtre, clair/sombre, accessibilité, cold start mesuré < 500 ms | ✅ |
| M7 | Qualité | Passage sur tous les dépôts locaux + `git/git`, zéro crash, zéro warning, captures d'écran vérifiées | ✅ |

Chaque jalon est fermé par une preuve (sortie de commande, test vert, capture)
consignée dans `docs/JOURNAL.md`.
