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

GitExtract      Le travail lourd. Lance `git` (Process), parse la sortie, produit
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
                debounce) et décision de reconstruction.
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

## Format Snapshot (v1)

Fichier unique, little-endian, sections alignées sur 8 octets.

```
Header  magic "LANESNAP" | version u32 | sectionCount u32 | repoPathOff u32 | flags u32
TOC     sectionCount × { kind u32, offset u64, length u64 }
Sections (tableaux de records de taille fixe, ou blob de chaînes)
  commits    n × CommitRecord (40 o) : timestamp i64, oid[20], authorIdx u32,
             messageOff u32, messageLen u16, parentStart u32 (dans parents),
             parentCount u8, lane u8
  parents    m × u32 (index de commit, ou 0xFFFFFFFF si hors snapshot)
  edges      par ligne : varint count, puis (fromLane u8, toLane u8, kind u8)
  edgeIndex  n × u32 offset dans edges
  authors    k × { nameOff u32, nameLen u16, emailOff u32, emailLen u16, commits u32 }
  refs       r × { nameOff u32, nameLen u16, kind u8, commitIdx u32 }
  files      f × { pathOff u32, pathLen u16, changes90d u32, lastTs i64, topAuthor u32 }
  changes    c × { fileIdx u32, authorIdx u32, ts i64 }   (90 derniers jours)
  health     { sizeBytes u64, looseObjects u32, packs u32, staleBranches u32, largest… }
  strings    blob UTF-8
```

Le reader ne copie rien : chaque section est une vue `UnsafeRawBufferPointer`
sur le mmap, lue avec `loadUnaligned`. Une chaîne devient `String` seulement
quand une vue la demande.

## Décisions

Voir `docs/DECISIONS.md`.
