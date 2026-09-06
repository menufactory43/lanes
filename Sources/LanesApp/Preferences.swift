import Foundation
import Snapshot

/// Préférences persistantes : dernier dépôt, récents, dernière visite par dépôt.
/// UserDefaults est déjà en mémoire au lancement : lecture gratuite.
@MainActor
enum Preferences {
    private static var d: UserDefaults { .standard }
    private static let lastRepoKey = "lastRepo"
    private static let recentsKey = "recentRepos"
    private static let visitsKey = "lastVisits"
    private static let discoveredKey = "discoveredRepos"
    private static let discoveredAtKey = "discoveredAt"

    static var discovered: [String] {
        get { d.stringArray(forKey: discoveredKey) ?? [] }
        set { d.set(newValue, forKey: discoveredKey); d.set(Date().timeIntervalSince1970, forKey: discoveredAtKey) }
    }
    static var discoveredAt: Date? {
        let t = d.double(forKey: discoveredAtKey); return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static var lastRepo: String? {
        get { d.string(forKey: lastRepoKey) }
        set { d.set(newValue, forKey: lastRepoKey) }
    }

    static var recents: [String] {
        get { d.stringArray(forKey: recentsKey) ?? [] }
        set { d.set(Array(newValue.prefix(10)), forKey: recentsKey) }
    }

    static func touchRecent(_ path: String) {
        var r = recents.filter { $0 != path }
        r.insert(path, at: 0)
        recents = r
        lastRepo = path
    }

    static func forgetRecent(_ path: String) {
        recents = recents.filter { $0 != path }
        if lastRepo == path { lastRepo = recents.first }
    }

    /// Dernière visite d'un dépôt, et enregistre la visite courante.
    static func consumeLastVisit(for repoPath: String, now: Date = Date()) -> Date? {
        var visits = d.dictionary(forKey: visitsKey) as? [String: Double] ?? [:]
        let key = Snapshot.key(forRepo: repoPath)
        let previous = visits[key].map { Date(timeIntervalSince1970: $0) }
        visits[key] = now.timeIntervalSince1970
        d.set(visits, forKey: visitsKey)
        return previous
    }

    static func peekLastVisit(for repoPath: String) -> Date? {
        let visits = d.dictionary(forKey: visitsKey) as? [String: Double] ?? [:]
        return visits[Snapshot.key(forRepo: repoPath)].map { Date(timeIntervalSince1970: $0) }
    }
}
