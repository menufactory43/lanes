import Foundation

/// Trouve les dépôts Git d'un dossier (par défaut la maison de l'utilisateur),
/// sans descendre dans les dossiers système ni les caches. Tourne en fond.
public enum RepoDiscovery {
    static let skipped: Set<String> = [
        "Library", "Applications", ".Trash", "node_modules", ".build", "build", "DerivedData",
        "Pods", "vendor", ".cache", "target", "dist", ".venv", "venv", "__pycache__", "Movies", "Music", "Pictures",
    ]

    public static func scan(root: URL = FileManager.default.homeDirectoryForCurrentUser, maxDepth: Int = 4, limit: Int = 200) -> [String] {
        var found: [String] = []
        var stack: [(URL, Int)] = [(root, 0)]
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        while let (dir, depth) = stack.popLast(), found.count < limit {
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { continue }
            var isRepo = false
            var subdirs: [URL] = []
            for child in children {
                guard let v = try? child.resourceValues(forKeys: Set(keys)), v.isDirectory == true, v.isSymbolicLink != true else { continue }
                let name = v.name ?? child.lastPathComponent
                if name == ".git" { isRepo = true; break }
                if name.hasPrefix(".") || skipped.contains(name) { continue }
                subdirs.append(child)
            }
            if isRepo {
                found.append(dir.path)   // on ne descend pas dans un dépôt (sous-modules exclus)
            } else if depth < maxDepth {
                for s in subdirs.reversed() { stack.append((s, depth + 1)) }
            }
        }
        return found.sorted { $0.lowercased() < $1.lowercased() }
    }
}
