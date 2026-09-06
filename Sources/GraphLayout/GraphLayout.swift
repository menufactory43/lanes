/// Attribution des voies d'un graphe de commits, à la manière de `git log --graph`
/// mais avec réutilisation des voies libérées pour rester compact.
///
/// Entrée : les commits dans l'ordre d'affichage (0 = le plus récent) et, pour
/// chacun, les index de ses parents (nil = parent hors du jeu).
/// Sortie : la voie de chaque commit et, pour chaque ligne, les arêtes qui la
/// relient à la ligne suivante.
///
/// Fonction pure, déterministe, O(n × voies actives).
public enum GraphLayout {
    public struct Edge: Equatable, Sendable {
        public var from: Int
        public var to: Int
        /// false = voie qui traverse ; true = part du commit vers un parent.
        public var toParent: Bool
        public init(from: Int, to: Int, toParent: Bool) { self.from = from; self.to = to; self.toParent = toParent }
    }

    public struct Result: Sendable {
        public var lanes: [Int]
        public var rowEdges: [[Edge]]
        public var maxLane: Int
    }

    public static func layout(count n: Int, parents: (Int) -> [Int?]) -> Result {
        var lanes = [Int](repeating: 0, count: n)
        var rowEdges = [[Edge]](repeating: [], count: n)
        var columns: [Int?] = []            // commit attendu par chaque colonne
        var waiting: [Int: Int] = [:]       // commit → colonne qui l'attend
        var maxLane = 0

        func allocate(near: Int) -> Int {
            // Première colonne libre à droite de `near`, sinon à gauche, sinon nouvelle.
            if near < columns.count {
                for c in near..<columns.count where columns[c] == nil { return c }
            }
            for c in 0..<columns.count where columns[c] == nil { return c }
            columns.append(nil)
            return columns.count - 1
        }

        for i in 0..<n {
            let col: Int
            if let c = waiting.removeValue(forKey: i) {
                col = c
            } else {
                col = allocate(near: 0)
            }
            lanes[i] = col
            maxLane = max(maxLane, col)

            // Voies qui traversent : toutes les colonnes actives sauf la nôtre.
            var edges: [Edge] = []
            for c in 0..<columns.count where c != col && columns[c] != nil {
                edges.append(Edge(from: c, to: c, toParent: false))
            }

            let ps = parents(i)
            columns[col] = nil
            var first = true
            for p in ps {
                defer { first = false }
                guard let p else { continue } // parent hors snapshot : la voie s'arrête
                if let existing = waiting[p] {
                    edges.append(Edge(from: col, to: existing, toParent: true))
                } else if first {
                    columns[col] = p
                    waiting[p] = col
                    edges.append(Edge(from: col, to: col, toParent: true))
                } else {
                    let c = allocate(near: col + 1)
                    columns[c] = p
                    waiting[p] = c
                    edges.append(Edge(from: col, to: c, toParent: true))
                }
            }
            // Ranger : passes d'abord, puis vers parents, pour un dessin stable.
            edges.sort { a, b in
                if a.toParent != b.toParent { return !a.toParent }
                if a.from != b.from { return a.from < b.from }
                return a.to < b.to
            }
            rowEdges[i] = edges

            // Compacter la queue de colonnes libres.
            while let last = columns.last, last == nil { columns.removeLast() }
        }
        return Result(lanes: lanes, rowEdges: rowEdges, maxLane: maxLane)
    }
}
