# Décisions d'architecture (ADR)

## ADR-1 : main.swift AppKit plutôt que `@main` SwiftUI App
`App`/`WindowGroup` ajoute 50 à 150 ms de mise en place de scènes au lancement
et ne permet pas de contrôler l'ordre exact fenêtre → première frame → travail
différé. On garde SwiftUI pour toutes les vues via `NSHostingView`.

## ADR-2 : `git` CLI pour l'extraction, pas libgit2 ni lecteur d'objets maison
L'extraction tourne hors du chemin critique, en arrière-plan. La robustesse
(packfiles, deltas, sous-modules, worktrees, LFS, encodages) vaut plus que la
pureté. Le chemin critique, lui, ne lit **que** le snapshot : c'est là que la
performance compte, et là qu'il n'y a aucune dépendance.

## ADR-3 : format binaire maison mappé, pas JSON/Codable/SQLite
Codable décode tout à l'ouverture (dizaines de ms pour 75 000 commits, et des
allocations). SQLite ouvre une connexion et exécute des requêtes. Le mmap d'un
fichier sectionné coûte une page fault par page lue, rien d'autre. Le prix : un
writer et un reader à tester soigneusement, version dans l'en-tête, et
reconstruction si la version ne correspond pas.

## ADR-4 : snapshot périmé détecté par empreinte, puis FSEvents en cours d'exécution
Au lancement, on compare une empreinte (HEAD, `for-each-ref`, mtime de l'index)
à celle stockée. C'est quelques ms et ça ne dépend pas de l'historique FSEvents.
Pendant que l'app est ouverte, FSEvents sur `.git` déclenche une reconstruction
avec debounce.

## ADR-5 : lecture seule
Aucune commande qui modifie le dépôt. Un tableau de bord qui lit peut être
irréprochable ; un client qui écrit est un autre produit.

## ADR-6 : tout en monospace, graphe compris
Un seul système de rendu (grille de caractères), une identité visuelle nette
inspirée de MDX Graphs, et le texte est ce qu'un Mac dessine le plus vite.
Police système monospace (SF Mono) : déjà en mémoire, zéro coût au lancement.

## ADR-7 : Swift 6, strict concurrency
Les snapshots sont immuables et `Sendable` ; l'extraction et la synchronisation
sont des `actor`. Le compilateur garantit qu'aucune vue ne touche un snapshot
en cours de réécriture : on échange une référence, jamais un état partagé.

## ADR-8 : `posix_spawn` plutôt que `Foundation.Process`, et le vrai binaire git
Mesuré sur cette machine : `Process` coûte 75 à 90 ms par invocation de `git`,
`posix_spawn` avec lecture des tubes par `poll` en coûte 3 quand on vise le
binaire réel d'Xcode ou des Command Line Tools. `/usr/bin/git` est un shim qui
relance la résolution `xcode-select` à chaque appel (+10 ms). Une extraction
fait une dizaine d'appels : c'est la différence entre 1,4 s et 50 ms sur un
petit dépôt, et une vérification d'empreinte au lancement qui devient gratuite.

## ADR-9 : le dashboard reçoit des fournisseurs, il n'appelle rien lui-même
Les fichiers d'un commit, l'ouverture dans le Finder, la recherche GitHub et
le clonage sont des fermetures injectées (`DashboardProviders`). Le module
`Dashboard` reste sans dépendance sur `GitExtract`, `Sync` ou le réseau, donc
il ne peut toujours pas déclencher `git` pendant un rendu, et il se prévisualise
avec des fournisseurs inertes.
