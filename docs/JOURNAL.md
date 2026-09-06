# Journal de construction

## 2026-09-06 — M1 à M7 en une session

### M1 Squelette
- Package SwiftPM, 9 modules statiques, `main.swift` AppKit, bundle assemblé par
  `Scripts/build-app.sh` (Info.plist, icône générée par `Scripts/make-icon.swift`,
  signature ad hoc). Binaire final : 1,1 Mo, aucune dépendance hors système.
- Preuve : `otool -L` ne liste que /System et /usr/lib.

### M2 Snapshot
- Format v1 sectionné (12 sections), writer avec table de chaînes internée,
  reader `mmap` zéro copie. 6 tests : aller-retour, magic, version, tronqué,
  chaîne hors limites, internement.
- Preuve : `swift test --filter SnapshotTests` vert. Ouverture d'un snapshot de
  85 557 commits (30 Mo) : 0,24 ms.

### M3 Extraction
- `GitRunner` : d'abord `Foundation.Process`, mesuré à 75–90 ms par appel.
  Réécrit sur `posix_spawn` + `poll`, 3 ms par appel avec le binaire git réel
  (ADR-8). Extraction de `git/git` : 3,9 s → 2,1 s ; d'un petit dépôt : 1,4 s → 0,12 s.
- `Extractor` : historique, références (tags annotés résolus, périmées,
  non fusionnées), changements 90 j, tailles, statut porcelain v2, santé.
- `GraphLayout` : voies compactes avec réutilisation, 6 tests dont 200 000
  commits linéaires en 0,24 s.
- Preuve : `ExtractorTests` construit un vrai dépôt temporaire (branches,
  fusion, tag, fichiers modifiés/non suivis) et vérifie chaque section.
- Robustesse : les 26 dépôts locaux de la machine passent, y compris trois
  dépôts sans aucun commit.

### M4 Dashboard
- Système de design `Glyph` : cadre pointillé à coins « + », Meter en █░,
  Spark, Stat, CellGrid, StackedBars, Leader, Tag. Largeur de cellule mesurée
  sur SF Mono (l'estimation 0,6 em tronquait les hashes).
- Bug trouvé et corrigé : `.id()` par ligne dans `List` forçait l'évaluation des
  85 557 lignes → première frame à 4,8 s. Sans : 385 ms.
- Bug trouvé et corrigé : lignes qui débordaient sur la colonne droite
  (message sans `maxWidth`), calendrier plus large que sa colonne (taille de
  cellule désormais calculée), étiquettes de refs bornées à 34 caractères.
- Sélection : `List(selection:)` remplacée par une sélection maison (fond ambre
  translucide + barre) pour rester dans la palette.
- Preuve : captures `docs/screenshots/`.

### M5 Synchronisation
- Empreinte SHA-256 (HEAD, refs, index, statut borné) comparée au lancement ;
  FSEvents sur `.git` et l'arbre de travail avec debounce 1,2 s ; revérification
  après chaque reconstruction.
- « Depuis ta dernière visite » : horodatage par dépôt dans UserDefaults.
- Preuve : app ouverte sur un clone, `git commit` dans le terminal → 8 s plus
  tard la vue montre le nouveau commit en tête, `main` déplacé, compteurs mis à
  jour. Relance : « 1 commit de Sync », fichier touché listé.

### M6 Finition
- Icône, fondu d'apparition 160 ms, clair/sombre via couleurs système,
  libellés d'accessibilité sur les cadres et les lignes, menus complets
  (ouvrir, récents, reconstruire, filtrer ⌘F), glisser-déposer de dossier,
  ouverture par `open -a Lanes --args`.
- Cold start mesuré (`LANES_MEASURE=1`), 3 lancements par dépôt, cache disque chaud :

  | Dépôt | première frame | interactif | warm |
  |---|---|---|---|
  | lifequest (839 commits) | 327–379 ms | 385–391 ms | 438–440 ms |
  | git/git (85 557 commits) | 383–410 ms | 434–461 ms | 495–533 ms |

  Répartition (git/git) : main atteint à 11 ms, NSApplication prêt à 82 ms,
  fenêtre à 121 ms, arbre SwiftUI posé à 252 ms, première frame à 385 ms.

### M7 Qualité
- `swift test` : 18 tests, 4 suites, verts. Zéro warning en release.
- Interaction vérifiée par événements souris réels (CGEvent) : filtre,
  sélection, détail du commit. État d'erreur (« pas un dépôt git ») vérifié.

### Limites connues
- Le premier lancement sur un dépôt construit le snapshot : l'utilisateur voit
  la progression, pas le tableau de bord. Le « woaw » commence au second.
- Historique tronqué à 250 000 commits ; voies au-delà de 255 dessinées sur la
  dernière voie.
- Le tri des auteurs fusionne par nom (pas par adresse) : deux personnes
  homonymes seraient confondues.
- Pas de navigation clavier dans le graphe (sélection à la souris).
