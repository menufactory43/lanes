import Foundation
import Observation
import Snapshot
import Analytics

/// État observable du tableau de bord. Le snapshot est immuable ; on échange
/// la référence, jamais un état partagé. Les analytics arrivent après la
/// première frame et peuvent être nil pendant quelques millisecondes.
@MainActor
@Observable
public final class DashboardModel {
    public private(set) var snapshot: Snapshot?
    public private(set) var analytics: Analytics?
    public var building: BuildState = .idle
    public var selectedCommit: Int?
    public var filter: String = ""
    public var lastVisit: Date?
    public var errorMessage: String?
    /// Dépôts connus, dans l'ordre d'affichage (récents d'abord, puis découverts).
    public var repos: [RepoEntry] = []
    public var currentRepoPath: String?
    public var discovering = false

    public enum BuildState: Equatable, Sendable {
        case idle
        case building(stage: String, detail: String)
        case failed(String)
    }

    public init() {}

    public func replace(snapshot: Snapshot?, analytics: Analytics?) {
        self.snapshot = snapshot
        self.analytics = analytics
        if let selectedCommit, let snapshot, selectedCommit >= snapshot.commits.count { self.selectedCommit = nil }
    }

    public func setAnalytics(_ a: Analytics) { analytics = a }

    public var isEmpty: Bool { snapshot == nil }

    /// Index des commits visibles selon le filtre (message, auteur, hash). Nil = tous.
    public var filteredIndices: [Int]? {
        guard let s = snapshot else { return nil }
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        var out: [Int] = []
        let n = s.commits.count
        for i in 0..<n {
            if s.message(i).lowercased().contains(q) || s.authors.name(s.commits.author(i)).lowercased().contains(q) || s.commits.fullHash(i).hasPrefix(q) {
                out.append(i)
                if out.count >= 5000 { break }
            }
        }
        return out
    }
}
