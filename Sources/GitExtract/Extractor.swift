import Foundation
import Snapshot
import GraphLayout

public enum ExtractStage: String, Sendable, CaseIterable {
    case locate, log, refs, changes, tree, status, layout, write

    /// Libellé affiché pendant la construction (Localizable.strings de l'app).
    public var localizedName: String {
        switch self {
        case .locate: String(localized: "locating")
        case .log: String(localized: "history")
        case .refs: String(localized: "refs")
        case .changes: String(localized: "recent files")
        case .tree: String(localized: "tree")
        case .status: String(localized: "working tree status")
        case .layout: String(localized: "graph lanes")
        case .write: String(localized: "writing")
        }
    }
}

public struct ExtractProgress: Sendable {
    public let stage: ExtractStage
    public let detail: String
}

public struct ExtractOptions: Sendable {
    /// Au-delà, l'historique est tronqué (les parents manquants terminent leur voie).
    public var maxCommits = 250_000
    public var recentDays = 90
    public var staleDays = 180
    public var maxStatusEntries = 5_000
    public var maxLargestFiles = 60
    public init() {}
}

/// Fabrique un snapshot complet d'un dépôt. Tout passe par `git` ; rien ici
/// n'est sur le chemin critique de lancement.
public struct Extractor: Sendable {
    public let repo: RepoInfo
    public let options: ExtractOptions
    private let progress: @Sendable (ExtractProgress) -> Void

    public init(repo: RepoInfo, options: ExtractOptions = .init(), progress: @escaping @Sendable (ExtractProgress) -> Void = { _ in }) {
        self.repo = repo
        self.options = options
        self.progress = progress
    }

    private func report(_ stage: ExtractStage, _ detail: String = "") { progress(.init(stage: stage, detail: detail)) }

    // MARK: Modèle intermédiaire

    struct Commit { var oid: [UInt8]; var parents: [String]; var ts: Int64; var author: Int; var subject: String }
    struct Author { var name: String; var email: String; var commits: Int; var first: Int64; var last: Int64 }
    struct Ref { var name: String; var kind: RefKind; var flags: UInt8; var oid: String }
    struct FileStat { var path: String; var changes: Int; var lastTs: Int64; var authorCounts: [Int: Int]; var size: UInt64 }
    struct Change { var file: Int; var author: Int; var ts: Int64; var commit: Int }
    struct StatusEntry { var path: String; var code: UInt8; var staged: Bool }

    /// Construit le snapshot et l'écrit dans `url`. Rend le nombre de commits.
    @discardableResult
    public func build(to url: URL, fingerprint: String) throws -> Int {
        let git = GitRunner(repoPath: repo.topLevel)
        let now = Int64(Date().timeIntervalSince1970)

        // 1. Historique --------------------------------------------------------
        report(.log)
        var commits: [Commit] = []
        var indexByOid: [String: Int] = [:]
        var authors: [Author] = []
        var authorIndex: [String: Int] = [:]
        let logData = try git.run([
            "log", "--all", "--exclude=refs/stash", "--date-order", "-n", "\(options.maxCommits)",
            "--format=%H%x1f%P%x1f%at%x1f%aN%x1f%aE%x1f%s%x1e",
        ])
        commits.reserveCapacity(logData.count / 120)
        for record in logData.split(separator: 0x1e) {
            let fields = record.split(separator: 0x1f, maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6 else { continue }
            let hash = String(decoding: fields[0], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard hash.count == 40 else { continue }
            let parents = String(decoding: fields[1], as: UTF8.self).split(separator: " ").map(String.init)
            let ts = Int64(String(decoding: fields[2], as: UTF8.self)) ?? 0
            let name = String(decoding: fields[3], as: UTF8.self)
            let email = String(decoding: fields[4], as: UTF8.self)
            var subject = String(decoding: fields[5], as: UTF8.self)
            if subject.hasSuffix("\n") { subject.removeLast() }
            let key = Self.authorKey(name: name, email: email)
            let a: Int
            if let i = authorIndex[key] {
                a = i
                authors[i].commits += 1
                authors[i].first = min(authors[i].first, ts)
                authors[i].last = max(authors[i].last, ts)
            } else {
                a = authors.count
                authorIndex[key] = a
                authors.append(Author(name: name, email: email, commits: 1, first: ts, last: ts))
            }
            indexByOid[hash] = commits.count
            commits.append(Commit(oid: Self.hexToBytes(hash), parents: parents, ts: ts, author: a, subject: subject))
        }
        report(.log, String(localized: "\(commits.count) commits"))

        // 2. Références --------------------------------------------------------
        report(.refs)
        var head = try git.string(["symbolic-ref", "-q", "--short", "HEAD"], allowFailure: true)
        let headOid = try git.string(["rev-parse", "-q", "--verify", "HEAD"], allowFailure: true)
        // Valeurs neutres écrites dans le snapshot ; le dashboard les traduit à l'affichage.
        if head.isEmpty { head = headOid.isEmpty ? "(no commits)" : "detached HEAD @ \(headOid.prefix(8))" }
        let unmerged: Set<String> = Set(
            (try git.string(["branch", "--no-merged", "HEAD", "--format=%(refname)"], allowFailure: true))
                .split(separator: "\n").map(String.init)
        )
        var refs: [Ref] = []
        let refData = try git.run(["for-each-ref", "--format=%(refname)%1f%(objectname)%1f%(*objectname)%1f%(committerdate:unix)%1f%(HEAD)"])
        for line in String(decoding: refData, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { continue }
            let full = f[0]
            let oid = f[2].isEmpty ? f[1] : f[2]   // tag annoté : objet pointé
            let kind: RefKind
            let short: String
            if full.hasPrefix("refs/heads/") { kind = .localBranch; short = String(full.dropFirst(11)) }
            else if full.hasPrefix("refs/remotes/") { kind = .remoteBranch; short = String(full.dropFirst(13)) }
            else if full.hasPrefix("refs/tags/") { kind = .tag; short = String(full.dropFirst(10)) }
            else if full.hasPrefix("refs/stash") { continue }
            else { kind = .other; short = full }
            if kind == .remoteBranch && short.hasSuffix("/HEAD") { continue }
            var flags: UInt8 = 0
            if f[4] == "*" { flags |= RefFlags.isHead }
            if kind == .localBranch {
                let ts = Int64(f[3]) ?? now
                if now - ts > Int64(options.staleDays) * 86_400 { flags |= RefFlags.stale }
                if unmerged.contains(full) { flags |= RefFlags.unmerged }
            }
            refs.append(Ref(name: short, kind: kind, flags: flags, oid: oid))
        }
        report(.refs, String(localized: "\(refs.count) refs"))

        // 3. Changements récents ------------------------------------------------
        report(.changes)
        var files: [FileStat] = []
        var fileIndex: [String: Int] = [:]
        var changes: [Change] = []
        let chData = try git.run([
            "log", "--all", "--exclude=refs/stash", "--since=\(options.recentDays).days", "--no-renames", "--name-only",
            "--format=%x1e%H%x1f%at%x1f%aE%x1f%aN",
        ], allowFailure: true)
        for record in chData.split(separator: 0x1e) {
            var lines = String(decoding: record, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            guard !lines.isEmpty else { continue }
            let header = lines.removeFirst().split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard header.count == 4 else { continue }
            let hash = String(header[0])
            let ts = Int64(header[1]) ?? 0
            let email = String(header[2]), name = String(header[3])
            let key = Self.authorKey(name: name, email: email)
            guard let author = authorIndex[key] else { continue }
            let commitIdx = indexByOid[hash] ?? Int(noIndex)
            for l in lines {
                let path = String(l)
                let fi: Int
                if let i = fileIndex[path] {
                    fi = i
                    files[i].changes += 1
                    files[i].lastTs = max(files[i].lastTs, ts)
                    files[i].authorCounts[author, default: 0] += 1
                } else {
                    fi = files.count
                    fileIndex[path] = fi
                    files.append(FileStat(path: path, changes: 1, lastTs: ts, authorCounts: [author: 1], size: 0))
                }
                changes.append(Change(file: fi, author: author, ts: ts, commit: commitIdx))
            }
        }
        report(.changes, String(localized: "\(files.count) files, \(changes.count) changes"))

        // 4. Arborescence (tailles) --------------------------------------------
        report(.tree)
        var trackedFiles = 0
        var largest: [(String, UInt64)] = []
        if !headOid.isEmpty {
            let treeData = try git.run(["ls-tree", "-r", "-l", "-z", "HEAD"], allowFailure: true)
            for entry in treeData.split(separator: 0) {
                // "<mode> <type> <oid> <size>\t<path>"
                guard let tab = entry.firstIndex(of: 0x09) else { continue }
                let metaStr = String(decoding: entry[entry.startIndex..<tab], as: UTF8.self)
                let path = String(decoding: entry[entry.index(after: tab)...], as: UTF8.self)
                let parts = metaStr.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 4, parts[1] == "blob" else { continue }
                trackedFiles += 1
                let size = UInt64(parts[3]) ?? 0
                if let i = fileIndex[path] { files[i].size = size }
                if largest.count < options.maxLargestFiles {
                    largest.append((path, size))
                    if largest.count == options.maxLargestFiles { largest.sort { $0.1 > $1.1 } }
                } else if size > largest[largest.count - 1].1 {
                    largest[largest.count - 1] = (path, size)
                    largest.sort { $0.1 > $1.1 }
                }
            }
            for (path, size) in largest where fileIndex[path] == nil {
                fileIndex[path] = files.count
                files.append(FileStat(path: path, changes: 0, lastTs: 0, authorCounts: [:], size: size))
            }
        }
        report(.tree, String(localized: "\(trackedFiles) tracked files"))

        // 5. État de travail ----------------------------------------------------
        report(.status)
        var status: [StatusEntry] = []
        var modified = 0, staged = 0, untracked = 0
        let stData = try git.run(["status", "--porcelain=v2", "-z", "--untracked-files=normal"], allowFailure: true)
        var fieldsZ = stData.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var idx = 0
        while idx < fieldsZ.count {
            let line = fieldsZ[idx]; idx += 1
            guard let first = line.first else { continue }
            switch first {
            case "1", "2":
                let parts = line.split(separator: " ", maxSplits: first == "1" ? 8 : 9, omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2, parts[1].count == 2 else { continue }
                let xy = Array(parts[1])
                let path = parts.last ?? ""
                if first == "2" { idx += 1 } // chemin d'origine du renommage
                if xy[0] != "." { staged += 1; if status.count < options.maxStatusEntries { status.append(.init(path: path, code: UInt8(xy[0].asciiValue ?? 63), staged: true)) } }
                if xy[1] != "." { modified += 1; if status.count < options.maxStatusEntries { status.append(.init(path: path, code: UInt8(xy[1].asciiValue ?? 63), staged: false)) } }
            case "u":
                let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
                modified += 1
                if status.count < options.maxStatusEntries { status.append(.init(path: parts.last ?? "", code: UInt8(ascii: "U"), staged: false)) }
            case "?":
                untracked += 1
                if status.count < options.maxStatusEntries { status.append(.init(path: String(line.dropFirst(2)), code: UInt8(ascii: "?"), staged: false)) }
            default: continue
            }
        }
        fieldsZ.removeAll()
        report(.status, String(localized: "\(modified) modified, \(staged) staged, \(untracked) untracked"))

        // 6. Santé -------------------------------------------------------------
        var sizeBytes: UInt64 = 0, loose = 0, packs = 0
        for line in (try git.string(["count-objects", "-v"], allowFailure: true)).split(separator: "\n") {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = UInt64(kv[1]) else { continue }
            switch kv[0] {
            case "count": loose = Int(v)
            case "packs": packs = Int(v)
            case "size", "size-pack": sizeBytes += v * 1024
            default: break
            }
        }

        var ahead = noIndex, behind: UInt32 = 0
        let lr = try git.string(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], allowFailure: true)
        let lrParts = lr.split(whereSeparator: { $0 == "\t" || $0 == " " })
        if lrParts.count == 2, let a = UInt32(lrParts[0]), let b = UInt32(lrParts[1]) { ahead = a; behind = b }
        let stashes = (try git.string(["stash", "list"], allowFailure: true)).split(separator: "\n").count

        // 7. Voies --------------------------------------------------------------
        report(.layout)
        let parentIdx: [[Int?]] = commits.map { c in c.parents.map { indexByOid[$0] } }
        let layout = GraphLayout.layout(count: commits.count) { parentIdx[$0] }

        // 8. Écriture ------------------------------------------------------------
        report(.write)
        var w = SnapshotWriter()

        var meta = RecordBuilder(stride: Layout.Meta.stride)
        let (po, pl) = w.intern(repo.topLevel); meta.put(po, at: Layout.Meta.repoPathOff); meta.put(pl, at: Layout.Meta.repoPathLen)
        let (no, nl) = w.intern(repo.name); meta.put(no, at: Layout.Meta.repoNameOff); meta.put(nl, at: Layout.Meta.repoNameLen)
        let (ho, hl) = w.intern(head); meta.put(ho, at: Layout.Meta.headOff); meta.put(hl, at: Layout.Meta.headLen)
        let (fo, fl) = w.intern(fingerprint); meta.put(fo, at: Layout.Meta.fingerprintOff); meta.put(fl, at: Layout.Meta.fingerprintLen)
        meta.put(now, at: Layout.Meta.builtAt)
        meta.put(UInt32(indexByOid[headOid] ?? Int(noIndex)), at: Layout.Meta.headCommit)
        w.set(.meta, Data(meta.bytes))

        var commitData = Data(capacity: commits.count * Layout.Commit.stride)
        var parentData = Data(capacity: commits.count * 4 + 64)
        var parentCursor: UInt32 = 0
        for (i, c) in commits.enumerated() {
            var r = RecordBuilder(stride: Layout.Commit.stride)
            r.put(c.ts, at: Layout.Commit.timestamp)
            r.put(c.oid, at: Layout.Commit.oid)
            r.put(UInt32(c.author), at: Layout.Commit.author)
            let (mo, ml) = w.intern(c.subject); r.put(mo, at: Layout.Commit.messageOff); r.put(ml, at: Layout.Commit.messageLen)
            let pc = min(parentIdx[i].count, 255)
            r.put(UInt8(pc), at: Layout.Commit.parentCount)
            r.put(UInt8(min(layout.lanes[i], 255)), at: Layout.Commit.lane)
            r.put(parentCursor, at: Layout.Commit.parentStart)
            var flags: UInt32 = 0
            if pc > 1 { flags |= CommitFlags.merge }
            if pc < parentIdx[i].count { flags |= CommitFlags.truncatedParents }
            r.put(flags, at: Layout.Commit.flags)
            commitData.append(contentsOf: r.bytes)
            for p in parentIdx[i].prefix(pc) { parentData.appendLE(UInt32(p ?? Int(noIndex))) }
            parentCursor += UInt32(pc)
        }
        w.set(.commits, commitData)
        w.set(.parents, parentData)

        var edgeIndex = Data(capacity: (commits.count + 1) * 4)
        var edgeData = Data(capacity: commits.count * 6)
        var edgeCount: UInt32 = 0
        for row in layout.rowEdges {
            edgeIndex.appendLE(edgeCount)
            for e in row {
                edgeData.append(contentsOf: [UInt8(min(e.from, 255)), UInt8(min(e.to, 255)), e.toParent ? EdgeKind.toParent.rawValue : EdgeKind.pass.rawValue])
                edgeCount += 1
            }
        }
        edgeIndex.appendLE(edgeCount)
        w.set(.edgeIndex, edgeIndex)
        w.set(.edges, edgeData)

        var authorData = Data()
        for a in authors {
            var r = RecordBuilder(stride: Layout.Author.stride)
            let (o, l) = w.intern(a.name); r.put(o, at: Layout.Author.nameOff); r.put(l, at: Layout.Author.nameLen)
            let (eo, el) = w.intern(a.email); r.put(eo, at: Layout.Author.emailOff); r.put(el, at: Layout.Author.emailLen)
            r.put(UInt32(a.commits), at: Layout.Author.commits)
            r.put(a.first, at: Layout.Author.firstTs)
            r.put(UInt32(clamping: max(0, a.last - a.first)), at: Layout.Author.lastTs)
            authorData.append(contentsOf: r.bytes)
        }
        w.set(.authors, authorData)

        var refData2 = Data()
        var staleCount = 0, localCount = 0, remoteCount = 0, tagCount = 0
        for ref in refs {
            var r = RecordBuilder(stride: Layout.Ref.stride)
            let (o, l) = w.intern(ref.name); r.put(o, at: Layout.Ref.nameOff); r.put(l, at: Layout.Ref.nameLen)
            r.put(ref.kind.rawValue, at: Layout.Ref.kind)
            r.put(ref.flags, at: Layout.Ref.flags)
            r.put(UInt32(indexByOid[ref.oid] ?? Int(noIndex)), at: Layout.Ref.commit)
            refData2.append(contentsOf: r.bytes)
            if ref.flags & RefFlags.stale != 0 { staleCount += 1 }
            switch ref.kind { case .localBranch: localCount += 1; case .remoteBranch: remoteCount += 1; case .tag: tagCount += 1; case .other: break }
        }
        w.set(.refs, refData2)

        var fileData = Data()
        for f in files {
            var r = RecordBuilder(stride: Layout.File.stride)
            let (o, l) = w.intern(f.path); r.put(o, at: Layout.File.pathOff); r.put(l, at: Layout.File.pathLen)
            r.put(UInt32(f.changes), at: Layout.File.changes)
            let top = f.authorCounts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key
            r.put(UInt32(top ?? Int(noIndex)), at: Layout.File.topAuthor)
            r.put(f.lastTs, at: Layout.File.lastTs)
            r.put(f.size, at: Layout.File.size)
            fileData.append(contentsOf: r.bytes)
        }
        w.set(.files, fileData)

        var changeData = Data(capacity: changes.count * Layout.Change.stride)
        for c in changes {
            var r = RecordBuilder(stride: Layout.Change.stride)
            r.put(UInt32(c.file), at: Layout.Change.file)
            r.put(UInt32(c.author), at: Layout.Change.author)
            r.put(c.ts, at: Layout.Change.timestamp)
            r.put(UInt32(c.commit), at: Layout.Change.commit)
            changeData.append(contentsOf: r.bytes)
        }
        w.set(.changes, changeData)

        var health = RecordBuilder(stride: Layout.Health.stride)
        health.put(sizeBytes, at: Layout.Health.sizeBytes)
        health.put(UInt32(loose), at: Layout.Health.looseObjects)
        health.put(UInt32(packs), at: Layout.Health.packs)
        health.put(UInt32(staleCount), at: Layout.Health.staleBranches)
        health.put(UInt32(trackedFiles), at: Layout.Health.trackedFiles)
        health.put(UInt32(modified), at: Layout.Health.modified)
        health.put(UInt32(staged), at: Layout.Health.staged)
        health.put(UInt32(untracked), at: Layout.Health.untracked)
        health.put(UInt32(localCount), at: Layout.Health.localBranches)
        health.put(UInt32(remoteCount), at: Layout.Health.remoteBranches)
        health.put(UInt32(tagCount), at: Layout.Health.tags)
        health.put(ahead, at: Layout.Health.ahead)
        health.put(behind, at: Layout.Health.behind)
        health.put(UInt32(stashes), at: Layout.Health.stashes)
        w.set(.health, Data(health.bytes))

        var statusData = Data()
        for s in status {
            var r = RecordBuilder(stride: Layout.Status.stride)
            let (o, l) = w.intern(s.path); r.put(o, at: Layout.Status.pathOff); r.put(l, at: Layout.Status.pathLen)
            r.put(s.code, at: Layout.Status.code)
            r.put(UInt8(s.staged ? 1 : 0), at: Layout.Status.staged)
            statusData.append(contentsOf: r.bytes)
        }
        w.set(.status, statusData)

        try w.write(to: url)
        return commits.count
    }

    /// Une même personne commite souvent avec plusieurs adresses : on regroupe
    /// par nom, et par adresse seulement si le nom manque.
    static func authorKey(name: String, email: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return n.isEmpty ? email.lowercased() : n
    }

    static func hexToBytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(20)
        var it = hex.utf8.makeIterator()
        func val(_ c: UInt8) -> UInt8 { c >= 97 ? c - 87 : (c >= 65 ? c - 55 : c - 48) }
        while let a = it.next(), let b = it.next() { out.append(val(a) << 4 | val(b)) }
        while out.count < 20 { out.append(0) }
        return Array(out.prefix(20))
    }
}
