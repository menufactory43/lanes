import Foundation
import Snapshot

/// Statistiques dérivées d'un snapshot. Fonctions pures, un seul passage sur
/// les commits quand c'est possible. Calculées après la première frame.
public struct Analytics: Sendable {
    public let calendar: ActivityCalendar
    public let authors: [AuthorStat]
    public let river: River
    public let clock: CodeClock
    public let hotFiles: [FileStat]
    public let directories: [DirectoryStat]
    public let largestFiles: [FileStat]
    public let refsByCommit: [Int: [RefLabel]]
    public let staleBranches: [String]
    public let unmergedBranches: [String]
    public let sinceLastVisit: SinceLastVisit
    public let firstCommit: Date?
    public let lastCommit: Date?

    public init(snapshot s: Snapshot, lastVisit: Date?, now: Date = Date(), calendar cal: Calendar = .current) {
        let n = s.commits.count
        var tz = cal
        tz.timeZone = .current

        // Calendrier 53 semaines, horloge 7×24, rivière mensuelle, par auteur.
        var dayCounts = [Int: Int]()          // jour (ordinal) → commits
        var clock = [Int](repeating: 0, count: 7 * 24)
        var monthly = [Int: [Int: Int]]()     // mois-ordinal → auteur → commits
        var recentByAuthor = [Int: Int]()
        var sinceCount = 0
        var sinceAuthors = Set<Int>()
        var sinceCommits: [Int] = []
        let sinceTs = lastVisit.map { Int64($0.timeIntervalSince1970) }
        let recentCutoff = Int64(now.timeIntervalSince1970) - 90 * 86_400
        let dayStart = tz.startOfDay(for: now)
        // Lundi de la semaine en cours, moins 52 semaines : la semaine courante est
        // la 53e colonne. (L'ancien calcul partait du dimanche et faisait tomber
        // la semaine courante hors de la grille du lundi au samedi.)
        let daysSinceMonday = (tz.component(.weekday, from: dayStart) + 5) % 7
        let calendarStart = tz.date(byAdding: .day, value: -(52 * 7 + daysSinceMonday), to: dayStart)!
        let calStartTs = Int64(calendarStart.timeIntervalSince1970)
        var first = Int64.max, last = Int64.min

        for i in 0..<n {
            let ts = s.commits.timestamp(i)
            if ts < first { first = ts }
            if ts > last { last = ts }
            let a = s.commits.author(i)
            if ts >= calStartTs {
                let d = Int((ts - calStartTs) / 86_400) // approximation par 24 h, corrigée ci-dessous
                dayCounts[d, default: 0] += 1
            }
            if ts >= recentCutoff { recentByAuthor[a, default: 0] += 1 }
            if let sinceTs, ts > sinceTs {
                sinceCount += 1
                sinceAuthors.insert(a)
                if sinceCommits.count < 8 { sinceCommits.append(i) }
            }
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let comps = tz.dateComponents([.weekday, .hour, .year, .month], from: date)
            let wd = ((comps.weekday ?? 1) + 5) % 7 // lundi = 0
            clock[wd * 24 + (comps.hour ?? 0)] += 1
            let monthKey = (comps.year ?? 1970) * 12 + ((comps.month ?? 1) - 1)
            monthly[monthKey, default: [:]][a, default: 0] += 1
        }

        // Calendrier : colonnes = semaines, lignes = jours (lundi en haut).
        var levels = [Double?](repeating: nil, count: 53 * 7)
        var maxDay = 0
        var total = 0
        let startWeekday = ((tz.component(.weekday, from: calendarStart)) + 5) % 7
        for d in 0..<(53 * 7) {
            let date = tz.date(byAdding: .day, value: d, to: calendarStart)!
            if date > now { break }
            let wd = (startWeekday + d) % 7
            let week = (startWeekday + d) / 7
            guard week < 53 else { break }
            let c = dayCounts[d] ?? 0
            total += c
            maxDay = max(maxDay, c)
            levels[wd * 53 + week] = Double(c)
        }
        let scaled = levels.map { $0.map { maxDay > 0 ? $0 / Double(maxDay) : 0 } }
        let streak = Self.currentStreak(dayCounts: dayCounts, todayIndex: Int((Int64(now.timeIntervalSince1970) - calStartTs) / 86_400))
        self.calendar = ActivityCalendar(levels: scaled, weeks: 53, total: total, maxPerDay: maxDay, currentStreak: streak, start: calendarStart)

        // Auteurs.
        var authors: [AuthorStat] = []
        for a in 0..<s.authors.count {
            authors.append(AuthorStat(index: a, name: s.authors.name(a), email: s.authors.email(a),
                                      commits: s.authors.commits(a),
                                      share: n > 0 ? Double(s.authors.commits(a)) / Double(n) : 0,
                                      recent: recentByAuthor[a] ?? 0,
                                      first: Date(timeIntervalSince1970: TimeInterval(s.authors.firstTimestamp(a))),
                                      last: Date(timeIntervalSince1970: TimeInterval(s.authors.lastTimestamp(a)))))
        }
        authors.sort { $0.commits > $1.commits || ($0.commits == $1.commits && $0.name < $1.name) }
        self.authors = authors

        // Rivière : 36 derniers mois (ou moins), 5 premiers auteurs + autres.
        let top = Array(authors.prefix(5).map(\.index))
        let months = monthly.keys.sorted()
        let lastMonths = Array(months.suffix(36))
        let range: [Int]
        if let a = lastMonths.first, let b = lastMonths.last { range = Array(a...b) } else { range = [] }
        var series = [[Double]](repeating: [Double](repeating: 0, count: range.count), count: top.count + 1)
        for (ci, m) in range.enumerated() {
            for (author, c) in monthly[m] ?? [:] {
                if let si = top.firstIndex(of: author) { series[si][ci] += Double(c) } else { series[top.count][ci] += Double(c) }
            }
        }
        self.river = River(series: series, authorIndices: top, months: range.map { m in
            var c = DateComponents(); c.year = m / 12; c.month = m % 12 + 1; c.day = 1
            return tz.date(from: c) ?? now
        })

        let cmax = clock.max() ?? 0
        self.clock = CodeClock(levels: clock.map { cmax > 0 ? Double($0) / Double(cmax) : 0 }, counts: clock)

        // Fichiers.
        var files: [FileStat] = []
        files.reserveCapacity(s.files.count)
        for f in 0..<s.files.count {
            files.append(FileStat(index: f, path: s.files.path(f), changes: s.files.changes(f),
                                  topAuthor: s.files.topAuthor(f).map { s.authors.name($0) },
                                  last: Date(timeIntervalSince1970: TimeInterval(s.files.lastTimestamp(f))),
                                  size: s.files.size(f)))
        }
        self.hotFiles = Array(files.filter { $0.changes > 0 }.sorted { $0.changes > $1.changes || ($0.changes == $1.changes && $0.path < $1.path) }.prefix(12))
        self.largestFiles = Array(files.filter { $0.size > 0 }.sorted { $0.size > $1.size }.prefix(8))

        // Répertoires : changements et propriétaire (auteur dominant) par premier niveau.
        var dirChanges = [String: Int]()
        var dirAuthors = [String: [Int: Int]]()
        var dirLast = [String: Int64]()
        for c in 0..<s.changes.count {
            let f = s.changes.file(c)
            guard f < files.count else { continue }
            let dir = Self.topDirectory(files[f].path)
            dirChanges[dir, default: 0] += 1
            dirAuthors[dir, default: [:]][s.changes.author(c), default: 0] += 1
            dirLast[dir] = max(dirLast[dir] ?? 0, s.changes.timestamp(c))
        }
        let dirTotal = max(1, dirChanges.values.reduce(0, +))
        self.directories = dirChanges.map { dir, c in
            let owner = dirAuthors[dir]?.max { $0.value < $1.value }
            return DirectoryStat(path: dir, changes: c, share: Double(c) / Double(dirTotal),
                                 owner: owner.map { s.authors.name($0.key) },
                                 ownerShare: owner.map { Double($0.value) / Double(c) } ?? 0,
                                 last: Date(timeIntervalSince1970: TimeInterval(dirLast[dir] ?? 0)))
        }.sorted { $0.changes > $1.changes || ($0.changes == $1.changes && $0.path < $1.path) }

        // Références par commit, branches périmées / non fusionnées.
        var byCommit = [Int: [RefLabel]]()
        var stale: [String] = [], unmerged: [String] = []
        for r in 0..<s.refs.count {
            let name = s.refs.name(r), kind = s.refs.kind(r), flags = s.refs.flags(r)
            if let c = s.refs.commit(r) {
                byCommit[c, default: []].append(RefLabel(name: name, kind: kind, isHead: flags & RefFlags.isHead != 0))
            }
            if flags & RefFlags.stale != 0 { stale.append(name) }
            if flags & RefFlags.unmerged != 0 { unmerged.append(name) }
        }
        for k in byCommit.keys { byCommit[k]!.sort { a, b in
            if a.isHead != b.isHead { return a.isHead }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.name < b.name
        } }
        self.refsByCommit = byCommit
        self.staleBranches = stale.sorted()
        self.unmergedBranches = unmerged.sorted()

        // Depuis la dernière visite : fichiers touchés.
        var sinceFiles = [Int: Int]()
        if let sinceTs {
            for c in 0..<s.changes.count where s.changes.timestamp(c) > sinceTs {
                sinceFiles[s.changes.file(c), default: 0] += 1
            }
        }
        let sinceFileStats = sinceFiles.compactMap { f, c -> FileStat? in
            guard f < files.count else { return nil }
            var fs = files[f]; fs.changes = c; return fs
        }.sorted { $0.changes > $1.changes || ($0.changes == $1.changes && $0.path < $1.path) }
        self.sinceLastVisit = SinceLastVisit(lastVisit: lastVisit, commits: sinceCount,
                                             authors: sinceAuthors.map { s.authors.name($0) }.sorted(),
                                             files: Array(sinceFileStats.prefix(8)),
                                             commitIndices: sinceCommits)
        self.firstCommit = first == .max ? nil : Date(timeIntervalSince1970: TimeInterval(first))
        self.lastCommit = last == .min ? nil : Date(timeIntervalSince1970: TimeInterval(last))
    }

    static func topDirectory(_ path: String) -> String {
        if let slash = path.firstIndex(of: "/") { return String(path[..<slash]) + "/" }
        return "./"
    }

    static func currentStreak(dayCounts: [Int: Int], todayIndex: Int) -> Int {
        var streak = 0
        var d = todayIndex
        if (dayCounts[d] ?? 0) == 0 { d -= 1 } // la journée en cours peut être vide
        while d >= 0, (dayCounts[d] ?? 0) > 0 { streak += 1; d -= 1 }
        return streak
    }
}

public struct ActivityCalendar: Sendable {
    public let levels: [Double?]   // 7 lignes × `weeks` colonnes
    public let weeks: Int
    public let total: Int
    public let maxPerDay: Int
    public let currentStreak: Int
    public let start: Date
}

public struct AuthorStat: Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    public let email: String
    public let commits: Int
    public let share: Double
    public let recent: Int
    public let first: Date
    public let last: Date
}

public struct River: Sendable {
    public let series: [[Double]]      // top auteurs + « autres »
    public let authorIndices: [Int]
    public let months: [Date]
}

public struct CodeClock: Sendable {
    public let levels: [Double]  // 7 × 24, lundi = ligne 0
    public let counts: [Int]
    public var peak: (day: Int, hour: Int)? {
        guard let m = counts.max(), m > 0, let i = counts.firstIndex(of: m) else { return nil }
        return (i / 24, i % 24)
    }
}

public struct FileStat: Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let path: String
    public var changes: Int
    public let topAuthor: String?
    public let last: Date
    public let size: UInt64
}

public struct DirectoryStat: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let changes: Int
    public let share: Double
    public let owner: String?
    public let ownerShare: Double
    public let last: Date
}

public struct RefLabel: Sendable, Hashable {
    public let name: String
    public let kind: RefKind
    public let isHead: Bool
}

public struct SinceLastVisit: Sendable {
    public let lastVisit: Date?
    public let commits: Int
    public let authors: [String]
    public let files: [FileStat]
    public let commitIndices: [Int]
}
