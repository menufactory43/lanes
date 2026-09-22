# Architecture — Lanes

## Thèse

Le temps de lancement est une contrainte structurelle, pas une optimisation.
Le code est organisé pour qu'il soit **impossible** de faire du travail lourd
avant la première frame par accident : les modules autorisés sur le chemin
critique n'ont pas accès aux modules qui font du travail lourd.

## Modules (Swift Package, tous statiques, fusionnés dans le binaire)

```
LanesApp        Composition root. main.swift AppKit (pas @main SwiftUI), AppDelegate,
                injection des dépendances. Seul module qui importe tout.

Shell           Chemin critique. LaunchPhase, LaunchMetrics (os_signpost + horloge
                monotone), Bootstrapper (ordonnance les tâches par phase).
                Importe : rien d'autre que Foundation/os.

Snapshot        Le cœur. Format binaire sectionné, versionné, mappé en mémoire.
                SnapshotWriter (construit un fichier), SnapshotReader (vues typées
                zéro copie sur le mmap). Aucune désérialisation au chargement.
                Importe : Foundation.

GraphLayout     Attribution des voies du graphe de commits. Fonction pure sur
                (commits, parents) → (lane par commit, arêtes par ligne).
                Importe : rien.

GitExtract      Le travail lourd. Lance `git` (`posix_spawn` + `poll`, ADR-8), parse la sortie, produit
                un Snapshot via SnapshotWriter + GraphLayout. Calcule l'empreinte
                du dépôt (HEAD, refs, index) pour savoir si le snapshot est périmé.
                Importe : Snapshot, GraphLayout.

Analytics       Statistiques dérivées d'un SnapshotReader : calendrier d'activité,
                auteurs, horloge du code, « depuis ta dernière visite ». Fonctions
                pures, calculées après la première frame.
                Importe : Snapshot.

Glyph           Système de design monospace. Tokens (couleurs, espacements sur
                grille de caractères), Frame (bord pointillé, coins « + »),
                Meter, Waffle, Spark, Stat. Aucune connaissance de Git.
                Importe : SwiftUI.

Dashboard       Les widgets Git (SwiftUI) et la vue racine. Lit un SnapshotReader
                et des résultats Analytics, dessine avec Glyph.
                Importe : Snapshot, Analytics, Glyph.

Sync            Surveillance du dépôt pendant l'exécution (FSEvents sur .git,
                debounce), découverte des dépôts sous la maison, recherche GitHub
                du panneau de clonage (seul accès réseau de l'app).
                Importe : GitExtract.
```

Règle de dépendance : `Dashboard` ne peut pas importer `GitExtract`. Le
dashboard ne sait pas comment un snapshot est fabriqué, il ne peut donc pas
déclencher `git` pendant le rendu.

## Cycle de vie d'un lancement

```
processStart ─ main.swift ─ AppDelegate.didFinishLaunching
   │ ouvre le snapshot du dernier dépôt (mmap, ~1 ms)
   │ crée NSWindow + NSHostingView(RootView(snapshot))
   ▼ firstFrame      ← tout ce que l'utilisateur voit est déjà là
   │ Bootstrapper .interactive : Analytics dérivées (quelques ms, hors chemin)
   ▼ interactive
   │ Bootstrapper .warm : empreinte du dépôt → si périmée, GitExtract en fond,
   │ puis swap atomique du snapshot ; démarrage de Sync (FSEvents)
   ▼ warm
```

Premier lancement sur un dépôt (pas de snapshot) : la vue affiche l'état de
construction avec progression, puis bascule. Le « woaw » commence au second.

## Format Snapshot (v2)

Fichier unique, little-endian, sections alignées sur 8 octets. Les offsets et
tailles font foi dans `Sources/Snapshot/Format.swift` ; toute modification de
layout incrémente la version, et un snapshot d'une autre version est reconstruit.

```
Header  magic "LANESNAP" | version u32 (= 2) | sectionCount u32 | réservé u64   (24 o)
TOC     sectionCount × { kind u32, réservé u32, offset u64, length u64 }       (24 o)
Sections (tableaux de records de taille fixe, ou blob de chaînes)
  meta       48 o : repoPath, repoName, head, empreinte (off u32 + len u16),
             builtAt i64, headCommit u32, flags u32
  strings    blob UTF-8 interné (chaque chaîne = offset u32 + longueur u16)
  commits    n × 48 o : timestamp i64, oid[20], author u32, message off/len,
             parentCount u8, lane u8, parentStart u32, flags u32 (fusion, parents tronqués)
  parents    m × u32 (index de commit, ou 0xFFFFFFFF si hors snapshot)
  edgeIndex  (n+1) × u32 : début des arêtes de chaque ligne
  edges      3 o par arête : fromLane u8, toLane u8, kind u8 (traverse / vers le parent)
  authors    k × 32 o : nom, e-mail, commits u32, premier et dernier timestamp
  refs       r × 12 o : nom, kind u8, flags u8 (HEAD, périmée, non fusionnée), commit u32
  files      f × 32 o : chemin, changements 90 j u32, auteur principal u32, lastTs i64, taille u64
  changes    c × 20 o : file u32, author u32, timestamp i64, commit u32   (90 derniers jours)
  health     64 o : taille, objets libres, packs, branches périmées, fichiers suivis,
             modifiés / indexés / non suivis, branches locales / distantes, tags,
             ahead / behind (0xFFFFFFFF = pas d'upstream), stashes   ← ajouts de la v2
  status     e × 8 o : chemin, code porcelain u8, indexé u8
```

Le reader ne copie rien : chaque section est une vue `UnsafeRawBufferPointer`
sur le mmap, lue avec `loadUnaligned`. Une chaîne devient `String` seulement
quand une vue la demande.

## Langues

Les chaînes de l'interface sont écrites en anglais dans le code (langue de
développement `en`) ; `Resources/fr.lproj` porte la traduction française et
les pluriels (`Localizable.stringsdict`). `Text("…")` et `String(localized:)`
lisent `Bundle.main` par défaut, y compris depuis les modules bibliothèque
(`Glyph`, `Dashboard`, `GitExtract`) : les tables vivent donc dans le bundle de
l'app, copiées par `Scripts/build-app.sh` et `Scripts/release.sh`. Le snapshot
ne contient aucun texte d'interface.

## Décisions

Voir `docs/DECISIONS.md`.
