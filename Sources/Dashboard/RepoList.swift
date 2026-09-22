import Foundation

/// Un dépôt connu de l'app, pour le cadre de navigation.
public struct RepoEntry: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let head: String?
    public let commits: Int?
    public let builtAt: Date?
    public let hasSnapshot: Bool

    public init(path: String, name: String, head: String?, commits: Int?, builtAt: Date?, hasSnapshot: Bool) {
        self.path = path; self.name = name; self.head = head; self.commits = commits; self.builtAt = builtAt; self.hasSnapshot = hasSnapshot
    }
}

/// HEAD tel qu'affiché. L'extracteur écrit des valeurs neutres (« (no commits) »,
/// « detached HEAD @ sha ») ; les snapshots construits avant la localisation
/// contiennent encore les formes françaises. Les deux sont traduites ici.
func displayHead(_ head: String) -> String {
    if head == "(no commits)" || head == "(aucun commit)" { return String(localized: "(no commits)") }
    for prefix in ["detached HEAD @ ", "HEAD détaché @ "] where head.hasPrefix(prefix) {
        let sha = String(head.dropFirst(prefix.count))
        return String(localized: "detached HEAD @ \(sha)")
    }
    return head
}
